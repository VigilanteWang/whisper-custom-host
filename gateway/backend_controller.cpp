#include "backend_controller.h"

#include "httplib.h"
#include "platform_process.h"

#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace whisper_gateway {
namespace {

std::vector<std::string> backend_arguments(const Config &config) {
  return {config.server_bin,
          "--host",
          config.backend_host,
          "--port",
          std::to_string(config.backend_port),
          "--inference-path",
          config.inference_path,
          "--convert",
          "--language",
          config.language,
          "--threads",
          std::to_string(config.threads),
          "--model",
          config.model_file};
}

ProcessIdentity backend_identity(const Config &config) {
  ProcessIdentity identity;
  identity.binary = config.server_bin;
  identity.model = config.model_file;
  identity.model_size = config.expected_model_size;
  identity.model_sha256 = config.expected_model_sha256;
  identity.port = config.backend_port;
  identity.host = config.backend_host;
  identity.argv = backend_arguments(config);
  identity.uid = ::geteuid();
  return identity;
}

ProcessRecord backend_record(pid_t pid, std::uint64_t start_epoch_ms,
                             const Config &config) {
  return {pid,
          start_epoch_ms,
          config.server_bin,
          config.model_file,
          config.expected_model_size,
          config.expected_model_sha256,
          config.backend_port,
          config.backend_host};
}

std::string read_trimmed_file(const fs::path &path) {
  std::ifstream input(path);
  if (!input) return {};
  std::ostringstream contents;
  contents << input.rdbuf();
  return trim_copy(contents.str());
}

std::string git_head_commit(const fs::path &source_dir) {
  fs::path git_dir = source_dir / ".git";
  std::error_code ec;
  if (fs::is_regular_file(git_dir, ec)) {
    const std::string pointer = read_trimmed_file(git_dir);
    constexpr const char *prefix = "gitdir:";
    if (pointer.rfind(prefix, 0) != 0) return {};
    git_dir = trim_copy(pointer.substr(std::char_traits<char>::length(prefix)));
    if (git_dir.is_relative()) git_dir = source_dir / git_dir;
  }
  const std::string head = read_trimmed_file(git_dir / "HEAD");
  constexpr const char *ref_prefix = "ref:";
  if (head.rfind(ref_prefix, 0) != 0) return lower_copy(head);
  const std::string reference =
      trim_copy(head.substr(std::char_traits<char>::length(ref_prefix)));
  const std::string loose = read_trimmed_file(git_dir / reference);
  if (!loose.empty()) return lower_copy(loose);

  std::ifstream packed(git_dir / "packed-refs");
  std::string line;
  while (std::getline(packed, line)) {
    if (line.empty() || line.front() == '#' || line.front() == '^') continue;
    const auto separator = line.find(' ');
    if (separator != std::string::npos &&
        line.substr(separator + 1U) == reference) {
      return lower_copy(line.substr(0, separator));
    }
  }
  return {};
}

} // namespace

const char *state_name(BackendState state) {
  switch (state) {
  case BackendState::Cold: return "cold";
  case BackendState::Starting: return "starting";
  case BackendState::Ready: return "ready";
  case BackendState::Stopping: return "stopping";
  case BackendState::Backoff: return "backoff";
  }
  return "cold";
}

RequestLease::RequestLease(BackendController *controller,
                           std::string request_id, TimePoint started)
    : controller_(controller), request_id_(std::move(request_id)),
      started_(started) {}

RequestLease::RequestLease(RequestLease &&other) noexcept
    : controller_(std::exchange(other.controller_, nullptr)),
      request_id_(std::move(other.request_id_)), started_(other.started_) {}

RequestLease &RequestLease::operator=(RequestLease &&other) noexcept {
  if (this != &other) {
    reset(500);
    controller_ = std::exchange(other.controller_, nullptr);
    request_id_ = std::move(other.request_id_);
    started_ = other.started_;
  }
  return *this;
}

RequestLease::~RequestLease() { reset(500); }

void RequestLease::finish(int status) { reset(status); }

void RequestLease::reset(int status) {
  if (controller_ == nullptr) return;
  BackendController *controller = std::exchange(controller_, nullptr);
  controller->finish_request(request_id_, started_, status);
}

BackendController::BackendController(Config config)
    : config_(std::move(config)) {}

BackendController::~BackendController() {
  request_shutdown();
  join();
}

bool BackendController::prepare_directories(std::string *error) {
  std::error_code ec;
  fs::create_directories(config_.upload_dir, ec);
  if (ec) {
    *error = "无法创建上传目录：" + ec.message();
    return false;
  }
  (void)::chmod(config_.upload_dir.c_str(), 0700);
  const auto create_parent = [&](const std::string &path,
                                 const char *label) -> bool {
    const fs::path parent = fs::path(path).parent_path();
    if (parent.empty()) return true;
    std::error_code parent_ec;
    fs::create_directories(parent, parent_ec);
    if (parent_ec) {
      *error = std::string("无法创建") + label + "：" + parent_ec.message();
      return false;
    }
    return true;
  };
  return create_parent(config_.pid_file, "PID 目录") &&
         create_parent(config_.gateway_pid_file, "网关 PID 目录") &&
         create_parent(config_.backend_log_file, "日志目录");
}

void BackendController::clean_old_uploads() {
  const auto cutoff = std::chrono::system_clock::now() - std::chrono::hours(24);
  std::error_code ec;
  for (const auto &entry : fs::directory_iterator(config_.upload_dir, ec)) {
    if (ec) break;
    struct stat st {};
    if (::stat(entry.path().c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
    const auto modified = std::chrono::system_clock::from_time_t(st.st_mtime);
    if (modified >= cutoff) continue;
    std::error_code remove_ec;
    fs::remove(entry.path(), remove_ec);
    if (!remove_ec) {
      log_event("upload_cleanup",
                log_field("file", entry.path().filename().string()));
    }
  }
}

bool BackendController::validate_startup(std::string *error) {
  if (::geteuid() == 0) {
    *error = "网关不能以 root 运行";
    return false;
  }
  if (!regular_file(config_.server_bin) ||
      ::access(config_.server_bin.c_str(), X_OK) != 0) {
    *error = "找不到可执行 whisper-server：" + config_.server_bin;
    return false;
  }
  if (!regular_file(config_.model_file)) {
    *error = "找不到模型：" + config_.model_file;
    return false;
  }
  if (!regular_file(config_.httplib_header)) {
    *error = "找不到固定 httplib.h：" + config_.httplib_header;
    return false;
  }
  if (config_.expected_commit.empty()) {
    *error = "必须提供 WHISPER_COMMIT 或 --expected-commit";
    return false;
  }
  const std::string actual_commit = git_head_commit(config_.source_dir);
  if (actual_commit != lower_copy(config_.expected_commit)) {
    *error = "whisper.cpp commit 不符：实际 " + actual_commit +
             "，预期 " + config_.expected_commit;
    return false;
  }
  if (config_.expected_model_size == 0 ||
      config_.expected_model_sha256.empty()) {
    *error = "必须提供模型大小和 SHA-256（WHISPER_MODEL_SIZE_BYTES/"
             "WHISPER_MODEL_SHA256 或对应 CLI 参数）";
    return false;
  }
  if (regular_file_size(config_.model_file) != config_.expected_model_size) {
    *error = "模型大小不符";
    return false;
  }
  if (lower_copy(sha256_file(config_.model_file)) !=
      lower_copy(config_.expected_model_sha256)) {
    *error = "模型 SHA-256 不符";
    return false;
  }
  if (!prepare_directories(error)) return false;
  clean_old_uploads();
  return true;
}

void BackendController::start() {
  if (!supervisor_thread_.joinable()) {
    supervisor_thread_ = std::thread([this] { supervisor_loop(); });
  }
  adopt_backend_if_safe();
}

void BackendController::request_shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_) return;
    shutting_down_ = true;
  }
  condition_.notify_all();
}

void BackendController::join() {
  if (supervisor_thread_.joinable()) supervisor_thread_.join();
}

std::optional<RequestLease>
BackendController::acquire_request(const std::string &request_id,
                                   TimePoint started, TimePoint deadline) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (shutting_down_ ||
      active_requests_ >=
          static_cast<std::size_t>(config_.max_pending_requests)) {
    return std::nullopt;
  }
  const auto inserted = request_deadlines_.try_emplace(request_id, deadline);
  // Request IDs are generated by the gateway and should be unique.  Reject a
  // duplicate instead of overwriting the first lease's deadline: otherwise
  // the first lease could erase the second lease's deadline on completion.
  if (!inserted.second) return std::nullopt;

  ++active_requests_;
  try {
    // Construct the optional only after the map insertion succeeded, and roll
    // both state changes back if copying the request ID (or optional storage)
    // throws.  A failed allocation must never strand an active request.
    RequestLease lease(this, request_id, started);
    return std::optional<RequestLease>(std::move(lease));
  } catch (...) {
    request_deadlines_.erase(inserted.first);
    if (active_requests_ > 0) --active_requests_;
    if (active_requests_ == 0) last_request_finished_ = Clock::now();
    throw;
  }
}

void BackendController::finish_request(const std::string &request_id,
                                       TimePoint started, int status) {
  const auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(
                            Clock::now() - started)
                            .count();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    request_deadlines_.erase(request_id);
    if (active_requests_ > 0) --active_requests_;
    if (active_requests_ == 0) last_request_finished_ = Clock::now();
  }
  condition_.notify_all();
  log_event("request_finished",
            log_field("request_id", request_id) +
                log_field("latency_ms", static_cast<std::uint64_t>(
                                            duration < 0 ? 0 : duration)) +
                log_field("status", static_cast<std::uint64_t>(status)));
}

void BackendController::adopt_backend_if_safe() {
  ProcessRecord record;
  if (!read_process_record(config_.pid_file, &record)) return;
  if (!process_matches(record, backend_identity(config_))) {
    log_event("backend_adoption_rejected",
              log_field("pid", static_cast<std::uint64_t>(record.pid)) +
                  log_field("reason", "identity_mismatch"));
    return;
  }
  const TimePoint adopted_at = Clock::now();
  std::lock_guard<std::mutex> lock(mutex_);
  backend_pid_ = record.pid;
  backend_start_epoch_ms_ = record.start_epoch_ms;
  backend_adopted_ = true;
  state_ = BackendState::Starting;
  state_changed_ = adopted_at;
  // The adopted backend may have been ready before this gateway process was
  // restarted.  Its old request history is unknowable, so begin a fresh idle
  // window rather than immediately stopping it from the controller's
  // construction-time timestamp.
  last_request_finished_ = adopted_at;
  log_event("backend_adopted",
            log_field("pid", static_cast<std::uint64_t>(backend_pid_)));
  condition_.notify_all();
}

bool BackendController::backend_is_safe_locked() const {
  if (backend_pid_ <= 0) return false;
  return process_matches(
      backend_record(backend_pid_, backend_start_epoch_ms_, config_),
      backend_identity(config_));
}

bool BackendController::backend_has_exited_locked() {
  if (backend_pid_ <= 0) return true;
  const ReapResult result = reap_child(backend_pid_, !backend_adopted_);
  return result.status == ReapStatus::Reaped ||
         result.status == ReapStatus::Exited ||
         result.status == ReapStatus::NotChild ||
         result.status == ReapStatus::Error;
}

bool BackendController::terminate_and_reap_backend_locked(pid_t pid) {
  if (pid <= 0 || backend_pid_ != pid) return false;

  const ProcessRecord record =
      backend_record(pid, backend_start_epoch_ms_, config_);
  const auto reap_until = [pid](const TimePoint deadline) {
    constexpr auto kPollInterval = std::chrono::milliseconds(25);
    for (;;) {
      const ReapResult result = reap_child(pid, true);
      if (result.status == ReapStatus::Reaped ||
          result.status == ReapStatus::NotChild) {
        return true;
      }
      if (Clock::now() >= deadline) return false;
      const auto remaining = std::chrono::duration_cast<
          std::chrono::milliseconds>(deadline - Clock::now());
      std::this_thread::sleep_for(std::min(kPollInterval, remaining));
    }
  };

  // A failed PID-record write happens immediately after spawn.  Give a
  // cooperative child a short, fixed grace period, then escalate.  Both
  // phases are deliberately bounded so a storage failure cannot strand an
  // untracked whisper-server indefinitely while the request holds the state
  // lock.
  constexpr auto kTermGrace = std::chrono::seconds(1);
  constexpr auto kKillGrace = std::chrono::seconds(2);
  bool term_sent = false;
  if (backend_is_safe_locked()) {
    std::string signal_error;
    term_sent = signal_if_matches(record, backend_identity(config_), SIGTERM,
                                  &signal_error);
    if (term_sent) {
      log_event("backend_record_cleanup_term",
                log_field("pid", static_cast<std::uint64_t>(pid)));
    } else {
      log_event("backend_record_cleanup_term_failed",
                log_field("pid", static_cast<std::uint64_t>(pid)) +
                    log_field("reason", signal_error));
    }
  } else {
    log_event("backend_record_cleanup_rejected",
              log_field("pid", static_cast<std::uint64_t>(pid)) +
                  log_field("reason", "identity_recheck_failed"));
  }

  if (reap_until(Clock::now() + kTermGrace)) {
    log_event("backend_record_cleanup_reaped",
              log_field("pid", static_cast<std::uint64_t>(pid)) +
                  log_field("signal", term_sent ? "TERM" : "none"));
    return true;
  }

  // Never escalate a PID whose identity is no longer exact.  A final reap
  // attempt above may have observed an exit without waitpid confirmation, but
  // an unknown live process must remain untouched.
  if (!backend_is_safe_locked()) {
    log_event("backend_record_cleanup_rejected",
              log_field("pid", static_cast<std::uint64_t>(pid)) +
                  log_field("reason", "identity_recheck_failed_before_kill"));
    return false;
  }
  std::string signal_error;
  if (!signal_if_matches(record, backend_identity(config_), SIGKILL,
                         &signal_error)) {
    log_event("backend_record_cleanup_kill_failed",
              log_field("pid", static_cast<std::uint64_t>(pid)) +
                  log_field("reason", signal_error));
    return false;
  }
  log_event("backend_record_cleanup_kill",
            log_field("pid", static_cast<std::uint64_t>(pid)));
  if (reap_until(Clock::now() + kKillGrace)) {
    log_event("backend_record_cleanup_reaped",
              log_field("pid", static_cast<std::uint64_t>(pid)) +
                  log_field("signal", "KILL"));
    return true;
  }
  log_event("backend_record_cleanup_reap_failed",
            log_field("pid", static_cast<std::uint64_t>(pid)));
  return false;
}

void BackendController::set_backoff_locked(const std::string &reason) {
  state_ = BackendState::Backoff;
  state_changed_ = Clock::now();
  backoff_until_ =
      state_changed_ +
      std::chrono::seconds(config_.start_failure_backoff_seconds);
  log_event("backend_backoff",
            log_field("reason", reason) +
                log_field("pid", backend_pid_ > 0
                                     ? static_cast<std::uint64_t>(backend_pid_)
                                     : 0));
  condition_.notify_all();
}

bool BackendController::launch_backend_locked(std::string *reason) {
  if (tcp_port_listening(config_.backend_host, config_.backend_port)) {
    *reason = "后端端口已被占用；不会终止未知进程";
    log_event("backend_port_occupied",
              log_field("port",
                        static_cast<std::uint64_t>(config_.backend_port)));
    return false;
  }
  const SpawnSpec spec{config_.server_bin, backend_arguments(config_),
                       config_.backend_log_file};
  SpawnResult spawned;
  std::string spawn_error;
  if (!spawn_process(spec, &spawned, &spawn_error)) {
    *reason = "posix_spawn 失败：" + spawn_error;
    return false;
  }
  const pid_t child = spawned.pid;
  backend_pid_ = spawned.pid;
  backend_start_epoch_ms_ = spawned.start_epoch_ms;
  backend_adopted_ = false;
  const ProcessRecord record =
      backend_record(child, backend_start_epoch_ms_, config_);
  if (backend_start_epoch_ms_ == 0 ||
      !write_process_record(config_.pid_file, record)) {
    log_event("backend_record_failed",
              log_field("pid", static_cast<std::uint64_t>(child)));
    const bool cleanup_confirmed =
        terminate_and_reap_backend_locked(child);
    if (cleanup_confirmed) {
      backend_pid_ = -1;
      backend_start_epoch_ms_ = 0;
      backend_adopted_ = false;
    } else {
      // Keep the identity in the state machine so BACKOFF can continue
      // observing/reaping this owned child.  Clearing it here would make an
      // unconfirmed process invisible to the supervisor.
      log_event("backend_record_cleanup_unconfirmed",
                log_field("pid", static_cast<std::uint64_t>(child)));
    }
    *reason = backend_start_epoch_ms_ == 0 ? "无法取得后端启动时间"
                                           : "无法写入后端身份记录";
    if (!cleanup_confirmed) *reason += "；无法确认后端已回收";
    return false;
  }
  state_ = BackendState::Starting;
  state_changed_ = Clock::now();
  log_event("backend_spawned",
            log_field("pid", static_cast<std::uint64_t>(child)));
  condition_.notify_all();
  return true;
}

bool BackendController::begin_backend(std::string *reason) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!shutting_down_) {
    const auto now = Clock::now();
    if (state_ == BackendState::Backoff) {
      if (backend_pid_ > 0) {
        if (backend_has_exited_locked()) {
          backend_pid_ = -1;
          backend_adopted_ = false;
          (void)::unlink(config_.pid_file.c_str());
        } else {
          *reason = "后端仍在退出";
          return false;
        }
      }
      if (now >= backoff_until_) {
        state_ = BackendState::Cold;
        state_changed_ = now;
      } else {
        *reason = "后端处于启动退避";
        return false;
      }
    }
    if (state_ == BackendState::Cold) {
      if (!launch_backend_locked(reason)) {
        set_backoff_locked(*reason);
        return false;
      }
      return true;
    }
    if (state_ == BackendState::Starting || state_ == BackendState::Ready) {
      return true;
    }
    condition_.wait_for(lock, std::chrono::milliseconds(100));
  }
  *reason = "网关正在退出";
  return false;
}

bool BackendController::backend_health(TimePoint deadline) const {
  httplib::Client client(config_.backend_host, config_.backend_port);
  if (!configure_client_deadline(client, deadline, std::chrono::seconds(1))) {
    return false;
  }
  auto result = client.Get("/health");
  return result && result->status == 200 &&
         result->body.find("\"status\":\"ok\"") != std::string::npos;
}

bool BackendController::wait_until_ready(TimePoint deadline,
                                         std::string *reason) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!shutting_down_) {
    if (state_ == BackendState::Ready) return true;
    if (state_ == BackendState::Backoff) {
      *reason = "后端启动失败或退出";
      return false;
    }
    if (state_ == BackendState::Cold) {
      *reason = "后端未运行";
      return false;
    }
    if (Clock::now() >= deadline) {
      *reason = "后端启动超时";
      return false;
    }
    condition_.wait_until(
        lock, std::min(deadline,
                       Clock::now() + std::chrono::milliseconds(250)));
  }
  *reason = "网关正在退出";
  return false;
}

BackendSnapshot BackendController::snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  BackendSnapshot value;
  value.state = state_;
  value.active_requests = active_requests_;
  value.pid = backend_pid_;
  const auto now = Clock::now();
  if (state_ == BackendState::Ready && active_requests_ == 0) {
    const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                             now - last_request_finished_)
                             .count();
    if (elapsed < config_.idle_timeout_seconds) {
      value.idle_remaining_seconds = static_cast<std::uint64_t>(
          config_.idle_timeout_seconds - elapsed);
    }
  }
  if (state_ == BackendState::Backoff && now < backoff_until_) {
    const auto remaining = std::chrono::duration_cast<std::chrono::seconds>(
                               backoff_until_ - now)
                               .count();
    value.backoff_remaining_seconds =
        static_cast<std::uint64_t>(std::max<std::int64_t>(remaining, 0));
  }
  return value;
}

bool BackendController::send_backend_signal(pid_t pid, int signal,
                                            const char *event) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (backend_pid_ != pid || !backend_is_safe_locked()) {
    log_event("backend_signal_rejected",
              log_field("pid", pid > 0 ? static_cast<std::uint64_t>(pid) : 0) +
                  log_field("reason", "identity_recheck_failed"));
    set_backoff_locked("identity_check_failed_before_signal");
    return false;
  }
  std::string signal_error;
  if (!signal_if_matches(
          backend_record(pid, backend_start_epoch_ms_, config_),
          backend_identity(config_), signal, &signal_error)) {
    log_event("backend_signal_failed",
              log_field("pid", static_cast<std::uint64_t>(pid)) +
                  log_field("reason", signal_error));
    return false;
  }
  log_event(event, log_field("pid", static_cast<std::uint64_t>(pid)));
  return true;
}

void BackendController::supervisor_loop() {
  for (;;) {
    pid_t action_pid = -1;
    bool send_term = false;
    bool send_kill = false;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      const auto now = Clock::now();
      if (shutting_down_) {
        if (backend_pid_ <= 0 || backend_has_exited_locked()) {
          backend_pid_ = -1;
          backend_adopted_ = false;
          (void)::unlink(config_.pid_file.c_str());
          return;
        }
        if (state_ != BackendState::Stopping) {
          if (backend_is_safe_locked()) {
            state_ = BackendState::Stopping;
            state_changed_ = now;
            action_pid = backend_pid_;
            send_term = true;
          } else {
            log_event("backend_shutdown_rejected",
                      log_field("pid", static_cast<std::uint64_t>(backend_pid_)) +
                          log_field("reason", "identity_mismatch"));
            set_backoff_locked("identity_check_failed_during_shutdown");
            return;
          }
        } else if (now - state_changed_ >
                   std::chrono::seconds(config_.shutdown_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            action_pid = backend_pid_;
            send_kill = true;
          } else {
            set_backoff_locked("identity_check_failed_during_shutdown");
          }
        }
      } else if (state_ == BackendState::Backoff) {
        if (backend_pid_ > 0 && backend_has_exited_locked()) {
          backend_pid_ = -1;
          backend_adopted_ = false;
          (void)::unlink(config_.pid_file.c_str());
          condition_.notify_all();
        } else if (backend_pid_ > 0 &&
                   now - state_changed_ >
                       std::chrono::seconds(config_.shutdown_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            action_pid = backend_pid_;
            send_kill = true;
          }
        } else if (backend_pid_ <= 0 && now >= backoff_until_) {
          state_ = BackendState::Cold;
          state_changed_ = now;
          condition_.notify_all();
        }
      } else if ((state_ == BackendState::Starting ||
                  state_ == BackendState::Ready ||
                  state_ == BackendState::Stopping) &&
                 backend_pid_ > 0) {
        if (backend_has_exited_locked()) {
          if (state_ == BackendState::Stopping) {
            backend_pid_ = -1;
            backend_adopted_ = false;
            (void)::unlink(config_.pid_file.c_str());
            state_ = BackendState::Cold;
            state_changed_ = now;
            condition_.notify_all();
          } else {
            log_event("backend_exit",
                      log_field("pid", static_cast<std::uint64_t>(backend_pid_)));
            backend_pid_ = -1;
            backend_adopted_ = false;
            (void)::unlink(config_.pid_file.c_str());
            set_backoff_locked("backend_unexpected_exit");
          }
        } else if (state_ == BackendState::Starting &&
                   now - state_changed_ >
                       std::chrono::seconds(config_.startup_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            action_pid = backend_pid_;
            send_term = true;
          }
          set_backoff_locked("startup_timeout");
        } else if (state_ == BackendState::Ready && active_requests_ == 0 &&
                   now - last_request_finished_ >=
                       std::chrono::seconds(config_.idle_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            state_ = BackendState::Stopping;
            state_changed_ = now;
            action_pid = backend_pid_;
            send_term = true;
          } else {
            set_backoff_locked("identity_check_failed_before_idle_stop");
          }
        } else if (state_ == BackendState::Stopping &&
                   now - state_changed_ >
                       std::chrono::seconds(config_.shutdown_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            action_pid = backend_pid_;
            send_kill = true;
          } else {
            set_backoff_locked("identity_check_failed_during_shutdown");
          }
        }
      }
      if (!send_term && !send_kill) {
        condition_.wait_for(lock, std::chrono::milliseconds(250));
      }
    }
    if (send_term && action_pid > 0) {
      (void)send_backend_signal(action_pid, SIGTERM, "backend_sigterm");
    }
    if (send_kill && action_pid > 0) {
      (void)send_backend_signal(action_pid, SIGKILL, "backend_sigkill");
    }

    BackendState current = BackendState::Cold;
    TimePoint health_deadline = Clock::now() + std::chrono::seconds(1);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (shutting_down_) continue;
      current = state_;
      for (const auto &entry : request_deadlines_) {
        if (entry.second < health_deadline) health_deadline = entry.second;
      }
    }
    if (current == BackendState::Starting &&
        backend_health(health_deadline)) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (state_ == BackendState::Starting && backend_pid_ > 0) {
        if (backend_is_safe_locked()) {
          const TimePoint ready_at = Clock::now();
          state_ = BackendState::Ready;
          state_changed_ = ready_at;
          if (backend_adopted_) last_request_finished_ = ready_at;
          log_event("backend_ready",
                    log_field("pid",
                              static_cast<std::uint64_t>(backend_pid_)));
          condition_.notify_all();
        } else {
          set_backoff_locked("identity_mismatch_before_ready");
        }
      }
    }
  }
}

} // namespace whisper_gateway
