// Lightweight OpenWhispr gateway for a demand-loaded whisper-server.
//
// The gateway deliberately exposes only the endpoints needed by OpenWhispr.
// It uses the pinned whisper.cpp httplib header for HTTP and starts the
// whisper-server binary as a regular-user child process on the loopback port.

#include "httplib.h"

#include <CommonCrypto/CommonDigest.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <spawn.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

extern char **environ;

namespace fs = std::filesystem;
using namespace httplib;

namespace {

constexpr int kExitUsage = 2;
constexpr int kExitConfiguration = 3;
constexpr const char *kMode = "on-demand";
constexpr uint64_t kProcessStartToleranceMs = 2000;

enum class BackendState {
  Cold,
  Starting,
  Ready,
  Stopping,
  Backoff,
};

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

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

template <typename F>
class ScopeExit {
public:
  explicit ScopeExit(F function) : function_(std::move(function)) {}
  ScopeExit(const ScopeExit &) = delete;
  ScopeExit &operator=(const ScopeExit &) = delete;
  ~ScopeExit() { function_(); }

private:
  F function_;
};

template <typename F>
ScopeExit<F> make_scope_exit(F function) {
  return ScopeExit<F>(std::move(function));
}

uint64_t unix_millis() {
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(now).count());
}

std::string json_escape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (const char raw : value) {
    const unsigned char c = static_cast<unsigned char>(raw);
    switch (c) {
    case '"': out += "\\\""; break;
    case '\\': out += "\\\\"; break;
    case '\n': out += "\\n"; break;
    case '\r': out += "\\r"; break;
    case '\t': out += "\\t"; break;
    default:
      if (c < 0x20) {
        char buf[7];
        std::snprintf(buf, sizeof(buf), "\\u%04x", c);
        out += buf;
      } else {
        out += static_cast<char>(c);
      }
    }
  }
  return out;
}

void log_event(const char *event, const std::string &extra = {}) {
  std::fprintf(stderr, "{\"event\":\"%s\",\"time_ms\":%llu%s}\n",
               event,
               static_cast<unsigned long long>(unix_millis()),
               extra.c_str());
  std::fflush(stderr);
}

std::string log_field(const char *name, const std::string &value) {
  return ",\"" + std::string(name) + "\":\"" + json_escape(value) + "\"";
}

std::string log_field(const char *name, uint64_t value) {
  return ",\"" + std::string(name) + "\":" + std::to_string(value);
}

// cpp-httplib creates the task queue through Server::new_task_queue.  The
// stock queue has an optional bound but does not expose a queue-full event;
// this small equivalent keeps the same TaskQueue contract while making a
// rejected socket observable.  A full queue causes cpp-httplib to close that
// connection; the handler-level active/429 limit remains the final guard.
class BoundedThreadPool final : public TaskQueue {
public:
  BoundedThreadPool(size_t worker_count, size_t max_queued_requests)
      : max_queued_requests_(max_queued_requests) {
    worker_count = std::max<size_t>(1, worker_count);
    workers_.reserve(worker_count);
    for (size_t i = 0; i < worker_count; ++i) {
      workers_.emplace_back([this] { worker_loop(); });
    }
  }

  BoundedThreadPool(const BoundedThreadPool &) = delete;
  BoundedThreadPool &operator=(const BoundedThreadPool &) = delete;

  ~BoundedThreadPool() override { shutdown(); }

  bool enqueue(std::function<void()> fn) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (shutting_down_ || jobs_.size() >= max_queued_requests_) {
        log_event("task_queue_full", log_field("limit", static_cast<uint64_t>(max_queued_requests_)));
        return false;
      }
      jobs_.push_back(std::move(fn));
    }
    condition_.notify_one();
    return true;
  }

  void shutdown() override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (shutting_down_) return;
      shutting_down_ = true;
    }
    condition_.notify_all();
    for (auto &worker : workers_) {
      if (worker.joinable()) worker.join();
    }
  }

private:
  void worker_loop() {
    for (;;) {
      std::function<void()> job;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        condition_.wait(lock, [this] { return shutting_down_ || !jobs_.empty(); });
        if (jobs_.empty()) {
          if (shutting_down_) return;
          continue;
        }
        job = std::move(jobs_.front());
        jobs_.pop_front();
      }
      job();
    }
  }

  size_t max_queued_requests_;
  bool shutting_down_ = false;
  std::deque<std::function<void()>> jobs_;
  std::vector<std::thread> workers_;
  std::mutex mutex_;
  std::condition_variable condition_;
};

std::string lower_copy(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

bool parse_u64(const std::string &value, uint64_t *out) {
  if (value.empty()) return false;
  uint64_t result = 0;
  for (const char raw : value) {
    const unsigned char c = static_cast<unsigned char>(raw);
    if (!std::isdigit(c)) return false;
    if (result > (std::numeric_limits<uint64_t>::max() - (c - '0')) / 10) return false;
    result = result * 10 + (c - '0');
  }
  *out = result;
  return true;
}

bool parse_positive_int(const std::string &value, int *out) {
  uint64_t n = 0;
  if (!parse_u64(value, &n) || n == 0 || n > static_cast<uint64_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  *out = static_cast<int>(n);
  return true;
}

bool parse_nonnegative_int(const std::string &value, int *out) {
  uint64_t n = 0;
  if (!parse_u64(value, &n) || n > static_cast<uint64_t>(std::numeric_limits<int>::max())) return false;
  *out = static_cast<int>(n);
  return true;
}

std::string trim_copy(std::string value);

bool parse_pid_file_contents(const std::string &contents, uint64_t *pid,
                             uint64_t *start_epoch_ms, bool *has_start) {
  std::istringstream stream(contents);
  std::string line;
  std::unordered_map<std::string, std::string> fields;
  while (std::getline(stream, line)) {
    const auto separator = line.find('=');
    if (separator != std::string::npos) fields[line.substr(0, separator)] = line.substr(separator + 1);
  }
  if (fields.empty()) {
    const auto first_line_end = contents.find_first_of("\r\n");
    const std::string first_line = trim_copy(contents.substr(0, first_line_end));
    if (!parse_u64(first_line, pid) || *pid == 0) return false;
    *has_start = false;
    *start_epoch_ms = 0;
    return true;
  }
  if (!parse_u64(fields["pid"], pid) || *pid == 0) return false;
  *has_start = parse_u64(fields["start_epoch_ms"], start_epoch_ms);
  if (!*has_start) *start_epoch_ms = 0;
  return true;
}

std::string getenv_or(const char *name, const std::string &fallback) {
  const char *value = std::getenv(name);
  return value == nullptr || *value == '\0' ? fallback : value;
}

std::string shell_quote(const std::string &value) {
  std::string result = "'";
  for (const char c : value) {
    if (c == '\'') result += "'\\''";
    else result += c;
  }
  result += "'";
  return result;
}

std::string command_output(const std::string &command) {
  std::string result;
  FILE *pipe = ::popen(command.c_str(), "r");
  if (pipe == nullptr) return result;
  char buf[512];
  while (std::fgets(buf, sizeof(buf), pipe) != nullptr) result += buf;
  ::pclose(pipe);
  while (!result.empty() && (result.back() == '\n' || result.back() == '\r')) result.pop_back();
  return result;
}

std::string canonical_or(const std::string &path) {
  char resolved[PATH_MAX];
  if (::realpath(path.c_str(), resolved) != nullptr) return resolved;
  return path;
}

bool regular_file(const std::string &path) {
  struct stat st{};
  return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

uint64_t regular_file_size(const std::string &path) {
  struct stat st{};
  if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return 0;
  return static_cast<uint64_t>(st.st_size);
}

std::string sha256_file(const std::string &path) {
  FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return {};
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  unsigned char buffer[1024 * 1024];
  size_t n = 0;
  while ((n = std::fread(buffer, 1, sizeof(buffer), file)) > 0) {
    CC_SHA256_Update(&ctx, buffer, static_cast<CC_LONG>(n));
  }
  const bool ok = std::ferror(file) == 0;
  std::fclose(file);
  if (!ok) return {};
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &ctx);
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (unsigned char c : digest) stream << std::setw(2) << static_cast<unsigned int>(c);
  return stream.str();
}

std::string trim_copy(std::string value) {
  const auto is_space = [](unsigned char c) { return std::isspace(c) != 0; };
  while (!value.empty() && is_space(static_cast<unsigned char>(value.front()))) value.erase(value.begin());
  while (!value.empty() && is_space(static_cast<unsigned char>(value.back()))) value.pop_back();
  return value;
}

bool configure_client_deadline(Client &client, TimePoint deadline,
                               std::chrono::milliseconds maximum) {
  const auto now = Clock::now();
  std::chrono::milliseconds remaining;
  if (deadline == TimePoint::max()) {
    remaining = maximum;
  } else if (now >= deadline) {
    return false;
  } else {
    remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
    if (remaining.count() <= 0) remaining = std::chrono::milliseconds(1);
    if (maximum.count() > 0 && remaining > maximum) remaining = maximum;
  }
  if (remaining.count() <= 0) return false;
  const auto millis = remaining.count();
  const time_t seconds = static_cast<time_t>(millis / 1000);
  const time_t micros = static_cast<time_t>((millis % 1000) * 1000);
  client.set_connection_timeout(seconds, micros);
  client.set_read_timeout(seconds, micros);
  client.set_write_timeout(seconds, micros);
  client.set_max_timeout(std::chrono::milliseconds(millis));
  return true;
}

struct Config {
  // The service topology is fixed: the gateway is the LAN-facing endpoint,
  // while whisper-server must remain loopback-only.  The backend host is not
  // read from the environment; the legacy CLI flag is validated below only
  // so an older generated LaunchAgent fails closed instead of widening scope.
  std::string gateway_host = "0.0.0.0";
  int gateway_port = 8080;
  std::string backend_host = "127.0.0.1";
  int backend_port = 18080;
  int idle_timeout_seconds = 300;
  int startup_timeout_seconds = 180;
  int shutdown_timeout_seconds = 15;
  int request_timeout_seconds = 900;
  int max_pending_requests = 4;
  uint64_t max_upload_bytes = 256ULL * 1024ULL * 1024ULL;
  int start_failure_backoff_seconds = 10;

  std::string root_dir = ".";
  std::string source_dir;
  std::string server_bin;
  std::string model_file;
  std::string public_dir;
  std::string inference_path = "/v1/audio/transcriptions";
  std::string language = "auto";
  int threads = 4;
  std::string expected_commit;
  std::string httplib_header;
  uint64_t expected_model_size = 0;
  std::string expected_model_sha256;
  std::string upload_dir;
  std::string gateway_pid_file;
  std::string pid_file;
  std::string backend_log_file;
  std::string git_bin = "/usr/bin/git";
};

void print_help(const char *argv0) {
  std::printf(
      "用法：%s [选项]\n\n"
      "网关：\n"
      "  --gateway-host HOST                 监听地址（正式服务固定 0.0.0.0；测试可覆盖）\n"
      "  --gateway-port PORT                 监听端口（默认 8080）\n"
      "  --backend-host HOST                 旧参数，仅接受 127.0.0.1，不进入 .env\n"
      "  --backend-port PORT                 后端端口（默认 18080）\n"
      "  --idle-timeout-seconds N            空闲回收秒数（默认 300）\n"
      "  --startup-timeout-seconds N         后端启动超时（默认 180）\n"
      "  --shutdown-timeout-seconds N        后端退出超时（默认 15）\n"
      "  --request-timeout-seconds N         单个请求超时（默认 900）\n"
      "  --max-pending-requests N            最大活动/等待请求数（默认 4）\n"
      "  --max-upload-bytes N                最大上传字节数（默认 268435456）\n"
      "  --start-failure-backoff-seconds N   启动失败退避秒数（默认 10）\n\n"
      "固定后端：\n"
      "  --root-dir DIR                      项目根目录\n"
      "  --source-dir DIR                    whisper.cpp 源码目录\n"
      "  --server-bin PATH                   whisper-server 绝对路径\n"
      "  --model PATH                        模型绝对路径\n"
      "  --public-dir DIR                    后端 public 目录\n"
      "  --inference-path PATH               后端转写路径\n"
      "  --language LANG                     后端语言参数\n"
      "  --threads N                         后端线程数\n"
      "  --expected-commit SHA               要求的 whisper.cpp commit\n"
      "  --source-commit SHA                 --expected-commit 的兼容别名\n"
      "  --httplib-header PATH                固定 httplib.h 路径\n"
      "  --model-size N                      模型大小（字节）\n"
      "  --model-sha256 SHA                  模型 SHA-256\n"
      "  --upload-dir DIR                    上传临时目录\n"
      "  --gateway-pid-file PATH             网关 PID 文件\n"
      "  --backend-bin PATH                  --server-bin 的兼容别名\n"
      "  --pid-file PATH                     后端身份记录文件\n"
      "  --backend-log-file PATH             后端日志文件\n"
      "  --help                              显示帮助\n",
      argv0);
}

bool consume_value(int argc, char **argv, int *index, std::string *value) {
  if (*index + 1 >= argc) return false;
  *value = argv[++(*index)];
  return true;
}

bool parse_args(int argc, char **argv, Config *config, std::string *error) {
  Config &c = *config;
  auto env_int = [&](const char *name, int *target) {
    const char *v = std::getenv(name);
    if (v != nullptr && *v != '\0') {
      int parsed = 0;
      if (!parse_positive_int(v, &parsed)) {
        *error = std::string("环境变量无效：") + name;
        return false;
      }
      *target = parsed;
    }
    return true;
  };
  auto env_u64 = [&](const char *name, uint64_t *target) {
    const char *v = std::getenv(name);
    if (v != nullptr && *v != '\0') {
      uint64_t parsed = 0;
      if (!parse_u64(v, &parsed) || parsed == 0) {
        *error = std::string("环境变量无效：") + name;
        return false;
      }
      *target = parsed;
    }
    return true;
  };
  if (!env_int("WHISPER_GATEWAY_PORT", &c.gateway_port) ||
      !env_int("WHISPER_BACKEND_PORT", &c.backend_port) ||
      !env_int("WHISPER_IDLE_TIMEOUT_SECONDS", &c.idle_timeout_seconds) ||
      !env_int("WHISPER_STARTUP_TIMEOUT_SECONDS", &c.startup_timeout_seconds) ||
      !env_int("WHISPER_SHUTDOWN_TIMEOUT_SECONDS", &c.shutdown_timeout_seconds) ||
      !env_int("WHISPER_REQUEST_TIMEOUT_SECONDS", &c.request_timeout_seconds) ||
      !env_int("WHISPER_MAX_PENDING_REQUESTS", &c.max_pending_requests) ||
      !env_u64("WHISPER_MAX_UPLOAD_BYTES", &c.max_upload_bytes)) {
    return false;
  }
  const char *backoff_env = std::getenv("WHISPER_START_FAILURE_BACKOFF_SECONDS");
  if (backoff_env != nullptr && *backoff_env != '\0' && !parse_nonnegative_int(backoff_env, &c.start_failure_backoff_seconds)) {
    *error = "环境变量无效：WHISPER_START_FAILURE_BACKOFF_SECONDS";
    return false;
  }

  c.root_dir = getenv_or("WHISPER_INSTALL_ROOT", c.root_dir);
  c.source_dir = getenv_or("WHISPER_SOURCE_DIR", c.root_dir + "/third_party/whisper.cpp");
  c.server_bin = getenv_or("WHISPER_SERVER_BIN", getenv_or("WHISPER_BACKEND_BIN", c.root_dir + "/build/whisper.cpp/bin/whisper-server"));
  c.model_file = getenv_or("WHISPER_MODEL_FILE", getenv_or("WHISPER_MODEL_PATH", c.root_dir + "/models/ggml-large-v3-turbo.bin"));
  c.public_dir = getenv_or("WHISPER_PUBLIC_DIR", c.source_dir + "/examples/server/public");
  c.inference_path = getenv_or("WHISPER_INFERENCE_PATH", c.inference_path);
  c.language = getenv_or("WHISPER_LANGUAGE", c.language);
  c.httplib_header = getenv_or("WHISPER_HTTPLIB_HEADER", c.source_dir + "/examples/server/httplib.h");
  c.expected_commit = getenv_or("WHISPER_COMMIT", "");
  c.expected_model_sha256 = getenv_or("WHISPER_MODEL_SHA256", "");
  const char *model_size_env = std::getenv("WHISPER_MODEL_SIZE_BYTES");
  if (model_size_env != nullptr && *model_size_env != '\0') {
    if (!parse_u64(model_size_env, &c.expected_model_size) || c.expected_model_size == 0) {
      *error = "环境变量无效：WHISPER_MODEL_SIZE_BYTES";
      return false;
    }
  }
  c.upload_dir = getenv_or("WHISPER_UPLOAD_DIR", c.root_dir + "/var/run/uploads");
  c.gateway_pid_file = getenv_or("WHISPER_GATEWAY_PID_FILE", c.root_dir + "/var/run/whisper-on-demand-gateway.pid");
  c.pid_file = getenv_or("WHISPER_ON_DEMAND_PID_FILE", getenv_or("WHISPER_BACKEND_PID_FILE", c.root_dir + "/var/run/whisper-on-demand-backend.state"));
  c.backend_log_file = getenv_or("WHISPER_ON_DEMAND_BACKEND_LOG", getenv_or("WHISPER_BACKEND_LOG_FILE", c.root_dir + "/var/log/whisper-server-on-demand.log"));

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") {
      print_help(argv[0]);
      std::exit(0);
    }
    std::string value;
    auto take = [&]() {
      if (!consume_value(argc, argv, &i, &value)) {
        *error = "选项缺少值：" + arg;
        return false;
      }
      return true;
    };
    if (arg == "--gateway-host") { if (!take()) return false; c.gateway_host = value; }
    else if (arg == "--gateway-port") { if (!take() || !parse_positive_int(value, &c.gateway_port)) { *error = "端口无效：" + value; return false; } }
    else if (arg == "--backend-host") { if (!take()) return false; c.backend_host = value; }
    else if (arg == "--backend-port") { if (!take() || !parse_positive_int(value, &c.backend_port)) { *error = "端口无效：" + value; return false; } }
    else if (arg == "--idle-timeout-seconds") { if (!take() || !parse_positive_int(value, &c.idle_timeout_seconds)) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--startup-timeout-seconds") { if (!take() || !parse_positive_int(value, &c.startup_timeout_seconds)) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--shutdown-timeout-seconds") { if (!take() || !parse_positive_int(value, &c.shutdown_timeout_seconds)) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--request-timeout-seconds") { if (!take() || !parse_positive_int(value, &c.request_timeout_seconds)) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--max-pending-requests") { if (!take() || !parse_positive_int(value, &c.max_pending_requests)) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--max-upload-bytes") { if (!take() || !parse_u64(value, &c.max_upload_bytes) || c.max_upload_bytes == 0) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--start-failure-backoff-seconds") { if (!take() || !parse_nonnegative_int(value, &c.start_failure_backoff_seconds)) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--root-dir") { if (!take()) return false; c.root_dir = value; }
    else if (arg == "--source-dir") { if (!take()) return false; c.source_dir = value; }
    else if (arg == "--server-bin" || arg == "--backend-bin") { if (!take()) return false; c.server_bin = value; }
    else if (arg == "--model") { if (!take()) return false; c.model_file = value; }
    else if (arg == "--public-dir") { if (!take()) return false; c.public_dir = value; }
    else if (arg == "--inference-path") { if (!take()) return false; c.inference_path = value; }
    else if (arg == "--language") { if (!take()) return false; c.language = value; }
    else if (arg == "--threads") { if (!take() || !parse_positive_int(value, &c.threads)) { *error = "数值无效：" + value; return false; } }
    else if (arg == "--expected-commit" || arg == "--source-commit") { if (!take()) return false; c.expected_commit = value; }
    else if (arg == "--httplib-header") { if (!take()) return false; c.httplib_header = value; }
    else if (arg == "--model-size") { if (!take() || !parse_u64(value, &c.expected_model_size) || c.expected_model_size == 0) { *error = "模型大小无效：" + value; return false; } }
    else if (arg == "--model-sha256") { if (!take()) return false; c.expected_model_sha256 = value; }
    else if (arg == "--upload-dir") { if (!take()) return false; c.upload_dir = value; }
    else if (arg == "--gateway-pid-file") { if (!take()) return false; c.gateway_pid_file = value; }
    else if (arg == "--backend-pid-file") { if (!take()) return false; c.pid_file = value; }
    else if (arg == "--pid-file") { if (!take()) return false; c.pid_file = value; }
    else if (arg == "--backend-log-file") { if (!take()) return false; c.backend_log_file = value; }
    else {
      *error = "未知选项：" + arg;
      return false;
    }
  }

  if (c.backend_host != "127.0.0.1") {
    *error = "后端地址必须为 127.0.0.1";
    return false;
  }
  c.backend_host = "127.0.0.1";
  if (c.gateway_port < 1 || c.gateway_port > 65535 || c.backend_port < 1 || c.backend_port > 65535 || c.gateway_port == c.backend_port) {
    *error = "网关和后端端口必须在 1-65535 且不能相同";
    return false;
  }
  if (c.inference_path.empty() || c.inference_path.front() != '/') {
    *error = "inference path 必须以 / 开头";
    return false;
  }
  c.source_dir = canonical_or(c.source_dir);
  c.server_bin = canonical_or(c.server_bin);
  c.model_file = canonical_or(c.model_file);
  c.public_dir = canonical_or(c.public_dir);
  c.httplib_header = canonical_or(c.httplib_header);
  return true;
}

void set_cors(Response &res) {
  res.set_header("Access-Control-Allow-Origin", "*");
  res.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set_header("Access-Control-Allow-Headers", "Content-Type, Accept, Authorization, X-Request-Id");
  res.set_header("Access-Control-Max-Age", "600");
}

void set_json(Response &res, int status, const std::string &body) {
  res.status = status;
  res.set_content(body, "application/json");
  set_cors(res);
}

std::string extract_boundary(const std::string &content_type) {
  const auto first_separator = content_type.find(';');
  const std::string media_type = lower_copy(trim_copy(content_type.substr(0, first_separator)));
  if (media_type != "multipart/form-data") return {};

  size_t cursor = first_separator == std::string::npos ? content_type.size() : first_separator + 1;
  while (cursor < content_type.size()) {
    const size_t next_separator = content_type.find(';', cursor);
    const std::string parameter = trim_copy(content_type.substr(
        cursor, next_separator == std::string::npos ? std::string::npos : next_separator - cursor));
    const size_t equals = parameter.find('=');
    if (equals != std::string::npos && lower_copy(trim_copy(parameter.substr(0, equals))) == "boundary") {
      std::string boundary = trim_copy(parameter.substr(equals + 1));
      if (boundary.size() >= 2 && boundary.front() == '"' && boundary.back() == '"') {
        boundary = boundary.substr(1, boundary.size() - 2);
      } else if (boundary.find('"') != std::string::npos) {
        return {};
      }
      // RFC 2046 bcharsnospace permits the punctuation below.  In
      // particular, do not narrow this to only alphanumeric, '-' and '_'.
      if (boundary.empty() || boundary.size() > 70) return {};
      for (const char raw : boundary) {
        const unsigned char c = static_cast<unsigned char>(raw);
        const bool punctuation = std::strchr("'()+_,-./:=?", static_cast<int>(c)) != nullptr;
        if (!std::isalnum(c) && !punctuation) return {};
      }
      return boundary;
    }
    if (next_separator == std::string::npos) break;
    cursor = next_separator + 1;
  }
  return {};
}

bool write_all(int fd, const char *data, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    const ssize_t n = ::write(fd, data + offset, length - offset);
    if (n > 0) { offset += static_cast<size_t>(n); continue; }
    if (n < 0 && errno == EINTR) continue;
    return false;
  }
  return true;
}

class TempUploadFile final {
public:
  TempUploadFile() = default;
  TempUploadFile(const TempUploadFile &) = delete;
  TempUploadFile &operator=(const TempUploadFile &) = delete;
  ~TempUploadFile() {
    close_fd();
    unlink_path();
  }

  bool create(const std::string &directory) {
    std::string template_path = directory + "/gateway-upload-XXXXXX";
    std::vector<char> writable(template_path.begin(), template_path.end());
    writable.push_back('\0');
    fd_ = ::mkstemp(writable.data());
    if (fd_ < 0) return false;
    path_ = writable.data();
    ::fchmod(fd_, 0600);
    return true;
  }

  int fd() const { return fd_; }
  const std::string &path() const { return path_; }

  bool close_fd() {
    if (fd_ < 0) return true;
    const int result = ::close(fd_);
    fd_ = -1;
    return result == 0;
  }

  bool unlink_path() {
    if (path_.empty()) return true;
    const int result = ::unlink(path_.c_str());
    const bool removed = result == 0 || errno == ENOENT;
    path_.clear();
    return removed;
  }

private:
  int fd_ = -1;
  std::string path_;
};

class ScopedFd final {
public:
  explicit ScopedFd(int fd = -1) : fd_(fd) {}
  ScopedFd(const ScopedFd &) = delete;
  ScopedFd &operator=(const ScopedFd &) = delete;
  ~ScopedFd() { close(); }

  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }
  int release() {
    const int released = fd_;
    fd_ = -1;
    return released;
  }
  bool close() {
    if (fd_ < 0) return true;
    const int result = ::close(fd_);
    fd_ = -1;
    return result == 0;
  }

private:
  int fd_ = -1;
};

struct ProcessRecord {
  pid_t pid = -1;
  uint64_t start_epoch_ms = 0;
  std::string binary;
  std::string model;
  uint64_t model_size = 0;
  std::string model_sha256;
  int port = 0;
  std::string host;
};

bool write_process_record(const std::string &path, const ProcessRecord &record) {
  const std::string tmp = path + ".tmp." + std::to_string(static_cast<long long>(::getpid()));
  ScopedFd fd(::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600));
  auto remove_tmp = make_scope_exit([&tmp] { ::unlink(tmp.c_str()); });
  if (!fd.valid()) return false;
  ::fchmod(fd.get(), 0600);
  std::ostringstream text;
  text << "pid=" << record.pid << '\n'
       << "start_epoch_ms=" << record.start_epoch_ms << '\n'
       << "binary=" << record.binary << '\n'
       << "model=" << record.model << '\n'
       << "model_size=" << record.model_size << '\n'
       << "model_sha256=" << lower_copy(record.model_sha256) << '\n'
       << "host=" << record.host << '\n'
       << "port=" << record.port << '\n';
  const std::string value = text.str();
  const bool ok = write_all(fd.get(), value.data(), value.size());
  const bool synced = ::fsync(fd.get()) == 0;
  if (!ok || !synced || !fd.close() || ::rename(tmp.c_str(), path.c_str()) != 0) return false;
  ::chmod(path.c_str(), 0600);
  return true;
}

bool read_process_record(const std::string &path, ProcessRecord *record) {
  std::ifstream file(path);
  if (!file) return false;
  std::unordered_map<std::string, std::string> fields;
  std::string line;
  while (std::getline(file, line)) {
    const auto pos = line.find('=');
    if (pos != std::string::npos) fields[line.substr(0, pos)] = line.substr(pos + 1);
  }
  uint64_t pid = 0, start = 0, port = 0;
  if (!parse_u64(fields["pid"], &pid) || pid == 0 || pid > static_cast<uint64_t>(std::numeric_limits<pid_t>::max()) ||
      !parse_u64(fields["start_epoch_ms"], &start) || start == 0 ||
      !parse_u64(fields["model_size"], &record->model_size) || record->model_size == 0 ||
      fields["model_sha256"].empty() || !parse_u64(fields["port"], &port) || port > 65535 ||
      fields["binary"].empty() || fields["model"].empty() || fields["host"].empty()) return false;
  record->pid = static_cast<pid_t>(pid);
  record->start_epoch_ms = start;
  record->port = static_cast<int>(port);
  record->binary = fields["binary"];
  record->model = fields["model"];
  record->model_sha256 = lower_copy(fields["model_sha256"]);
  record->host = fields["host"];
  return true;
}

bool process_alive(pid_t pid) {
  if (pid <= 0) return false;
  if (::kill(pid, 0) == 0) return true;
  return errno == EPERM;
}

std::string process_binary(pid_t pid) {
  char path[PROC_PIDPATHINFO_MAXSIZE];
  const int n = proc_pidpath(pid, path, sizeof(path));
  return n > 0 ? std::string(path, static_cast<size_t>(n)) : std::string();
}

uint64_t process_start_epoch_ms(pid_t pid) {
  struct proc_bsdinfo info{};
  const int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  if (n != static_cast<int>(sizeof(info))) return 0;
  return static_cast<uint64_t>(info.pbi_start_tvsec) * 1000ULL +
         static_cast<uint64_t>(info.pbi_start_tvusec) / 1000ULL;
}

bool process_is_zombie(pid_t pid) {
  if (pid <= 0) return false;
  struct proc_bsdinfo info{};
  const int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  return n == static_cast<int>(sizeof(info)) && info.pbi_status == SZOMB;
}

bool process_uid_matches(pid_t pid) {
  if (pid <= 0) return false;
  struct proc_bsdinfo info{};
  const int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  return n == static_cast<int>(sizeof(info)) && info.pbi_uid == ::geteuid();
}

bool read_process_argv(pid_t pid, const std::string &expected_binary,
                       std::vector<std::string> *argv) {
  if (pid <= 0) return false;
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  if (::sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0 || size < sizeof(int)) return false;
  std::vector<char> buffer(size);
  if (::sysctl(mib, 3, buffer.data(), &size, nullptr, 0) != 0 || size < sizeof(int)) return false;
  int argc = 0;
  std::memcpy(&argc, buffer.data(), sizeof(argc));
  if (argc <= 0 || argc > 1024) return false;
  const char *cursor = buffer.data() + sizeof(argc);
  const char *end = buffer.data() + size;
  std::vector<std::string> strings;
  while (cursor < end) {
    const size_t length = ::strnlen(cursor, static_cast<size_t>(end - cursor));
    if (cursor + length >= end) break;
    strings.emplace_back(cursor, length);
    cursor += length + 1;
  }
  const std::string canonical_binary = canonical_or(expected_binary);
  for (size_t start = 0; start + static_cast<size_t>(argc) <= strings.size(); ++start) {
    if (canonical_or(strings[start]) != canonical_binary) continue;
    if (start + 1 >= strings.size() || strings[start + 1] != "--host") continue;
    argv->assign(strings.begin() + static_cast<std::ptrdiff_t>(start),
                 strings.begin() + static_cast<std::ptrdiff_t>(start + static_cast<size_t>(argc)));
    return true;
  }
  return false;
}

bool process_matches(const ProcessRecord &record, const Config &config) {
  if (!process_alive(record.pid) || process_is_zombie(record.pid) || !process_uid_matches(record.pid)) return false;
  if (canonical_or(process_binary(record.pid)) != canonical_or(config.server_bin)) return false;
  if (record.binary != config.server_bin || record.model != config.model_file ||
      record.model_size != config.expected_model_size ||
      lower_copy(record.model_sha256) != lower_copy(config.expected_model_sha256) ||
      record.host != config.backend_host || record.port != config.backend_port) return false;
  const uint64_t actual_start = process_start_epoch_ms(record.pid);
  if (actual_start == 0 || record.start_epoch_ms == 0) return false;
  const uint64_t difference = actual_start > record.start_epoch_ms ? actual_start - record.start_epoch_ms : record.start_epoch_ms - actual_start;
  if (difference > kProcessStartToleranceMs) return false;

  const std::vector<std::string> expected_argv = {
      config.server_bin, "--host", config.backend_host,
      "--port", std::to_string(config.backend_port),
      "--inference-path", config.inference_path,
      "--convert", "--language", config.language,
      "--threads", std::to_string(config.threads),
      "--model", config.model_file};
  std::vector<std::string> actual_argv;
  if (!read_process_argv(record.pid, expected_argv[0], &actual_argv) || actual_argv.size() != expected_argv.size()) return false;
  for (size_t index = 0; index < expected_argv.size(); ++index) {
    if (index == 0) {
      if (canonical_or(actual_argv[index]) != canonical_or(expected_argv[index])) return false;
    } else if (actual_argv[index] != expected_argv[index]) {
      return false;
    }
  }
  return true;
}

bool tcp_port_listening(const std::string &host, int port) {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return false;
  struct sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(port));
  if (::inet_pton(AF_INET, host.c_str(), &address.sin_addr) != 1) {
    ::close(fd);
    return false;
  }
  const int flags = ::fcntl(fd, F_GETFL, 0);
  ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  const int result = ::connect(fd, reinterpret_cast<struct sockaddr *>(&address), sizeof(address));
  if (result == 0 || errno == EINPROGRESS) {
    fd_set write_set;
    FD_ZERO(&write_set);
    FD_SET(fd, &write_set);
    struct timeval timeout{0, 100000};
    const int selected = ::select(fd + 1, nullptr, &write_set, nullptr, &timeout);
    if (selected > 0) {
      int error = 0;
      socklen_t len = sizeof(error);
      ::getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len);
      ::close(fd);
      return error == 0;
    }
  }
  ::close(fd);
  return false;
}

class Gateway {
public:
  explicit Gateway(Config config) : config_(std::move(config)) {}
  ~Gateway() { request_shutdown(); join_threads(); }

  bool validate_startup(std::string *error);
  int run();

private:
  bool prepare_directories(std::string *error);
  void clean_old_uploads();
  void adopt_backend_if_safe();
  bool backend_is_safe_locked() const;
  bool backend_has_exited_locked();
  bool begin_backend(std::string *reason);
  bool launch_backend_locked(std::string *reason);
  bool wait_until_ready(TimePoint deadline, std::string *reason);
  bool backend_health(TimePoint deadline) const;
  void supervisor_loop();
  void signal_loop();
  bool send_backend_signal(pid_t pid, int signal, const char *event);
  void request_shutdown();
  void join_threads();
  bool write_gateway_pid_file();
  void remove_gateway_pid_file();
  void set_backoff_locked(const std::string &reason);
  void handle_post(const Request &req, Response &res, const ContentReader &reader);
  void handle_health(const Request &, Response &res);
  void handle_ready(const Request &, Response &res);
  void handle_options(const Request &, Response &res);
  std::string health_json_locked() const;
  std::string ready_json_locked() const;
  bool validate_request(const Request &req, Response &res) const;
  std::string make_request_id();
  void finish_request(const std::string &request_id, TimePoint started, int status);
  bool forward_file(const Request &req, const std::string &request_id,
                   const std::string &file_path, uint64_t file_size,
                   const std::string &content_type, TimePoint deadline,
                   Response &res);
  void set_error(Response &res, int status, const std::string &message,
                 const std::string &retry_after = {});

  Config config_;
  Server server_;
  std::mutex mutex_;
  std::condition_variable condition_;
  BackendState state_ = BackendState::Cold;
  pid_t backend_pid_ = -1;
  uint64_t backend_start_epoch_ms_ = 0;
  bool backend_adopted_ = false;
  size_t active_requests_ = 0;
  TimePoint last_request_finished_ = Clock::now();
  TimePoint state_changed_ = Clock::now();
  TimePoint backoff_until_ = TimePoint::min();
  bool shutting_down_ = false;
  std::atomic<uint64_t> request_counter_{0};
  std::unordered_map<std::string, TimePoint> request_deadlines_;
  std::thread supervisor_thread_;
  std::thread signal_thread_;
  sigset_t signal_set_{};
};

bool Gateway::prepare_directories(std::string *error) {
  std::error_code ec;
  fs::create_directories(config_.upload_dir, ec);
  if (ec) { *error = "无法创建上传目录：" + ec.message(); return false; }
  ::chmod(config_.upload_dir.c_str(), 0700);
  const auto create_parent = [&](const std::string &path, const char *label) -> bool {
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
  if (!create_parent(config_.pid_file, "PID 目录") ||
      !create_parent(config_.gateway_pid_file, "网关 PID 目录") ||
      !create_parent(config_.backend_log_file, "日志目录")) return false;
  return true;
}

void Gateway::clean_old_uploads() {
  const auto cutoff = std::chrono::system_clock::now() - std::chrono::hours(24);
  std::error_code ec;
  for (const auto &entry : fs::directory_iterator(config_.upload_dir, ec)) {
    if (ec) break;
    struct stat st{};
    if (::stat(entry.path().c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
    const auto modified = std::chrono::system_clock::from_time_t(st.st_mtime);
    if (modified < cutoff) {
      std::error_code remove_ec;
      fs::remove(entry.path(), remove_ec);
      if (!remove_ec) log_event("upload_cleanup", log_field("file", entry.path().filename().string()));
    }
  }
}

bool Gateway::validate_startup(std::string *error) {
  if (::geteuid() == 0) { *error = "网关不能以 root 运行"; return false; }
  if (!regular_file(config_.server_bin) || ::access(config_.server_bin.c_str(), X_OK) != 0) {
    *error = "找不到可执行 whisper-server：" + config_.server_bin; return false;
  }
  if (!regular_file(config_.model_file)) { *error = "找不到模型：" + config_.model_file; return false; }
  if (!regular_file(config_.httplib_header)) { *error = "找不到固定 httplib.h：" + config_.httplib_header; return false; }
  // whisper-server's set_base_dir is optional in the pinned server; the
  // current source tree does not ship a public/ directory, but the inference
  // and health routes work without one.  The optional path is intentionally
  // not passed to the backend in this build.
  if (config_.expected_commit.empty()) {
    *error = "必须提供 WHISPER_COMMIT 或 --expected-commit"; return false;
  }
  const std::string actual_commit = command_output(shell_quote(config_.git_bin) + " -C " + shell_quote(config_.source_dir) + " rev-parse HEAD 2>/dev/null");
  if (actual_commit != config_.expected_commit) {
    *error = "whisper.cpp commit 不符：实际 " + actual_commit + "，预期 " + config_.expected_commit; return false;
  }
  if (config_.expected_model_size == 0 || config_.expected_model_sha256.empty()) {
    *error = "必须提供模型大小和 SHA-256（WHISPER_MODEL_SIZE_BYTES/WHISPER_MODEL_SHA256 或对应 CLI 参数）"; return false;
  }
  if (regular_file_size(config_.model_file) != config_.expected_model_size) {
    *error = "模型大小不符"; return false;
  }
  const std::string actual_hash = sha256_file(config_.model_file);
  if (lower_copy(actual_hash) != lower_copy(config_.expected_model_sha256)) {
    *error = "模型 SHA-256 不符"; return false;
  }
  if (!prepare_directories(error)) return false;
  clean_old_uploads();
  return true;
}

void Gateway::adopt_backend_if_safe() {
  ProcessRecord record;
  if (!read_process_record(config_.pid_file, &record)) return;
  Config config_copy = config_;
  if (!process_matches(record, config_copy)) {
    log_event("backend_adoption_rejected", log_field("pid", static_cast<uint64_t>(record.pid)) + log_field("reason", "identity_mismatch"));
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  backend_pid_ = record.pid;
  backend_start_epoch_ms_ = record.start_epoch_ms;
  backend_adopted_ = true;
  state_ = BackendState::Starting;
  state_changed_ = Clock::now();
  log_event("backend_adopted", log_field("pid", static_cast<uint64_t>(backend_pid_)));
  condition_.notify_all();
}

bool Gateway::backend_is_safe_locked() const {
  if (backend_pid_ <= 0) return false;
  ProcessRecord record;
  record.pid = backend_pid_;
  record.start_epoch_ms = backend_start_epoch_ms_;
  record.binary = config_.server_bin;
  record.model = config_.model_file;
  record.model_size = config_.expected_model_size;
  record.model_sha256 = config_.expected_model_sha256;
  record.host = config_.backend_host;
  record.port = config_.backend_port;
  return process_matches(record, config_);
}

bool Gateway::backend_has_exited_locked() {
  if (backend_pid_ <= 0) return true;
  if (!backend_adopted_) {
    int status = 0;
    const pid_t waited = ::waitpid(backend_pid_, &status, WNOHANG);
    if (waited == backend_pid_) return true;
    if (waited < 0 && errno != EINTR && errno != ECHILD) return true;
    // A child can become a zombie between the first nonblocking wait and the
    // process-state query.  Perform an explicit second wait so it is reaped
    // before the PID is cleared.
    if (process_is_zombie(backend_pid_)) {
      const pid_t reaped = ::waitpid(backend_pid_, &status, WNOHANG);
      if (reaped == backend_pid_) return true;
      if (reaped < 0 && errno == ECHILD) return true;
      return false;
    }
  } else if (process_is_zombie(backend_pid_)) {
    // An adopted process is not our child and must never be waitpid'ed.  A
    // zombie is nevertheless terminal; its original parent owns reaping.
    return true;
  }
  return !process_alive(backend_pid_);
}

void Gateway::set_backoff_locked(const std::string &reason) {
  state_ = BackendState::Backoff;
  state_changed_ = Clock::now();
  backoff_until_ = state_changed_ + std::chrono::seconds(config_.start_failure_backoff_seconds);
  log_event("backend_backoff", log_field("reason", reason) + log_field("pid", backend_pid_ > 0 ? static_cast<uint64_t>(backend_pid_) : 0));
  condition_.notify_all();
}

bool Gateway::launch_backend_locked(std::string *reason) {
  if (tcp_port_listening(config_.backend_host, config_.backend_port)) {
    *reason = "后端端口已被占用；不会终止未知进程";
    log_event("backend_port_occupied", log_field("port", static_cast<uint64_t>(config_.backend_port)));
    return false;
  }
  int log_fd = ::open(config_.backend_log_file.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (log_fd < 0) { *reason = "无法打开后端日志"; return false; }
  ::fchmod(log_fd, 0600);

  std::vector<std::string> args = {
      config_.server_bin, "--host", config_.backend_host,
      "--port", std::to_string(config_.backend_port),
      "--inference-path", config_.inference_path,
      "--convert", "--language", config_.language,
      "--threads", std::to_string(config_.threads),
      "--model", config_.model_file};
  std::vector<char *> argv;
  argv.reserve(args.size() + 1);
  for (auto &arg : args) argv.push_back(const_cast<char *>(arg.c_str()));
  argv.push_back(nullptr);

  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) {
    ::close(log_fd);
    *reason = "无法初始化后端日志重定向";
    return false;
  }
  if (posix_spawn_file_actions_adddup2(&actions, log_fd, STDOUT_FILENO) != 0 ||
      posix_spawn_file_actions_adddup2(&actions, log_fd, STDERR_FILENO) != 0 ||
      posix_spawn_file_actions_addclose(&actions, log_fd) != 0) {
    posix_spawn_file_actions_destroy(&actions);
    ::close(log_fd);
    *reason = "无法配置后端日志重定向";
    return false;
  }
  // The gateway consumes lifecycle signals with sigwait.  Do not inherit
  // that blocked mask into whisper-server: its own SIGTERM handler must be
  // able to receive the graceful shutdown signal.
  posix_spawnattr_t attributes;
  if (posix_spawnattr_init(&attributes) != 0) {
    posix_spawn_file_actions_destroy(&actions);
    ::close(log_fd);
    *reason = "无法初始化后端进程属性";
    return false;
  }
  sigset_t child_signal_mask;
  sigemptyset(&child_signal_mask);
  if (posix_spawnattr_setsigmask(&attributes, &child_signal_mask) != 0 ||
      posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK) != 0) {
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    ::close(log_fd);
    *reason = "无法配置后端信号掩码";
    return false;
  }
  pid_t child = -1;
  const int spawn_result = ::posix_spawn(&child, config_.server_bin.c_str(), &actions, &attributes, argv.data(), environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  ::close(log_fd);
  if (spawn_result != 0) {
    *reason = "posix_spawn 失败：" + std::string(std::strerror(spawn_result));
    return false;
  }
  backend_pid_ = child;
  backend_start_epoch_ms_ = unix_millis();
  backend_adopted_ = false;
  if (backend_start_epoch_ms_ == 0) {
    log_event("backend_record_failed", log_field("pid", static_cast<uint64_t>(child)) + log_field("reason", "zero_start_time"));
    const bool safe_identity = backend_is_safe_locked();
    if (safe_identity) {
      (void)::kill(child, SIGTERM);
      (void)::waitpid(child, nullptr, 0);
    } else {
      log_event("backend_cleanup_rejected", log_field("pid", static_cast<uint64_t>(child)) + log_field("reason", "identity_recheck_failed"));
    }
    backend_pid_ = -1;
    *reason = "无法取得后端启动时间";
    return false;
  }
  ProcessRecord record{child, backend_start_epoch_ms_, config_.server_bin, config_.model_file,
                       config_.expected_model_size, config_.expected_model_sha256,
                       config_.backend_port, config_.backend_host};
  if (!write_process_record(config_.pid_file, record)) {
    log_event("backend_record_failed", log_field("pid", static_cast<uint64_t>(child)));
    // Do not leave an unmanaged child if the identity record cannot be made.
    const bool safe_identity = backend_is_safe_locked();
    if (safe_identity) {
      (void)::kill(child, SIGTERM);
      (void)::waitpid(child, nullptr, 0);
    } else {
      log_event("backend_cleanup_rejected", log_field("pid", static_cast<uint64_t>(child)) + log_field("reason", "identity_recheck_failed"));
    }
    backend_pid_ = -1;
    *reason = "无法写入后端身份记录";
    return false;
  }
  state_ = BackendState::Starting;
  state_changed_ = Clock::now();
  log_event("backend_spawned", log_field("pid", static_cast<uint64_t>(child)));
  condition_.notify_all();
  return true;
}

bool Gateway::begin_backend(std::string *reason) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!shutting_down_) {
    const auto now = Clock::now();
    if (state_ == BackendState::Backoff) {
      if (backend_pid_ > 0) {
        if (backend_has_exited_locked()) {
          backend_pid_ = -1;
          backend_adopted_ = false;
          ::unlink(config_.pid_file.c_str());
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
    if (state_ == BackendState::Starting || state_ == BackendState::Ready) return true;
    condition_.wait_for(lock, std::chrono::milliseconds(100));
  }
  *reason = "网关正在退出";
  return false;
}

bool Gateway::backend_health(TimePoint deadline) const {
  Client client(config_.backend_host, config_.backend_port);
  if (!configure_client_deadline(client, deadline, std::chrono::seconds(1))) return false;
  auto result = client.Get("/health");
  return result && result->status == 200 && result->body.find("\"status\":\"ok\"") != std::string::npos;
}

bool Gateway::wait_until_ready(TimePoint deadline, std::string *reason) {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!shutting_down_) {
    if (state_ == BackendState::Ready) return true;
    if (state_ == BackendState::Backoff) { *reason = "后端启动失败或退出"; return false; }
    if (state_ == BackendState::Cold) { *reason = "后端未运行"; return false; }
    if (Clock::now() >= deadline) { *reason = "后端启动超时"; return false; }
    condition_.wait_until(lock, std::min(deadline, Clock::now() + std::chrono::milliseconds(250)));
  }
  *reason = "网关正在退出";
  return false;
}

void Gateway::supervisor_loop() {
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
          ::unlink(config_.pid_file.c_str());
          return;
        }
        if (state_ != BackendState::Stopping) {
          if (backend_is_safe_locked()) {
            state_ = BackendState::Stopping;
            state_changed_ = now;
            action_pid = backend_pid_;
            send_term = true;
          } else {
            log_event("backend_shutdown_rejected", log_field("pid", static_cast<uint64_t>(backend_pid_)) + log_field("reason", "identity_mismatch"));
            set_backoff_locked("identity_check_failed_during_shutdown");
            return;
          }
        } else if (now - state_changed_ > std::chrono::seconds(config_.shutdown_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            action_pid = backend_pid_;
            send_kill = true;
          } else {
            log_event("backend_shutdown_timeout", log_field("pid", static_cast<uint64_t>(backend_pid_)));
            set_backoff_locked("identity_check_failed_during_shutdown");
          }
        }
      } else if (state_ == BackendState::Backoff) {
        if (backend_pid_ > 0 && backend_has_exited_locked()) {
          backend_pid_ = -1;
          backend_adopted_ = false;
          ::unlink(config_.pid_file.c_str());
          condition_.notify_all();
        } else if (backend_pid_ > 0 && now - state_changed_ > std::chrono::seconds(config_.shutdown_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            action_pid = backend_pid_;
            send_kill = true;
          }
        } else if (backend_pid_ <= 0 && now >= backoff_until_) {
          state_ = BackendState::Cold;
          state_changed_ = now;
          condition_.notify_all();
        }
      } else if ((state_ == BackendState::Starting || state_ == BackendState::Ready || state_ == BackendState::Stopping) && backend_pid_ > 0) {
        if (backend_has_exited_locked()) {
          if (state_ == BackendState::Stopping) {
            backend_pid_ = -1;
            backend_adopted_ = false;
            ::unlink(config_.pid_file.c_str());
            state_ = BackendState::Cold;
            state_changed_ = now;
            condition_.notify_all();
          } else {
            log_event("backend_exit", log_field("pid", static_cast<uint64_t>(backend_pid_)));
            backend_pid_ = -1;
            backend_adopted_ = false;
            ::unlink(config_.pid_file.c_str());
            set_backoff_locked("backend_unexpected_exit");
          }
        } else if (state_ == BackendState::Starting) {
          if (now - state_changed_ > std::chrono::seconds(config_.startup_timeout_seconds)) {
            if (backend_is_safe_locked()) {
              action_pid = backend_pid_;
              send_term = true;
            }
            set_backoff_locked("startup_timeout");
          }
        } else if (state_ == BackendState::Ready && active_requests_ == 0 &&
                   now - last_request_finished_ >= std::chrono::seconds(config_.idle_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            state_ = BackendState::Stopping;
            state_changed_ = now;
            action_pid = backend_pid_;
            send_term = true;
          } else {
            set_backoff_locked("identity_check_failed_before_idle_stop");
          }
        } else if (state_ == BackendState::Stopping && now - state_changed_ > std::chrono::seconds(config_.shutdown_timeout_seconds)) {
          if (backend_is_safe_locked()) {
            action_pid = backend_pid_;
            send_kill = true;
          } else {
            log_event("backend_shutdown_timeout", log_field("pid", static_cast<uint64_t>(backend_pid_)));
            set_backoff_locked("identity_check_failed_during_shutdown");
          }
        }
      }
      if (!send_term && !send_kill) condition_.wait_for(lock, std::chrono::milliseconds(250));
    }
    if (send_term && action_pid > 0) {
      (void)send_backend_signal(action_pid, SIGTERM, "backend_sigterm");
    }
    if (send_kill && action_pid > 0) {
      (void)send_backend_signal(action_pid, SIGKILL, "backend_sigkill");
    }
    if (!shutting_down_) {
      BackendState current;
      TimePoint health_deadline = Clock::now() + std::chrono::seconds(1);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        current = state_;
        for (const auto &entry : request_deadlines_) {
          if (entry.second < health_deadline) health_deadline = entry.second;
        }
      }
      if (current == BackendState::Starting && backend_health(health_deadline)) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ == BackendState::Starting && backend_pid_ > 0) {
          if (backend_is_safe_locked()) {
            state_ = BackendState::Ready;
            state_changed_ = Clock::now();
            log_event("backend_ready", log_field("pid", static_cast<uint64_t>(backend_pid_)));
            condition_.notify_all();
          } else {
            set_backoff_locked("identity_mismatch_before_ready");
          }
        }
      }
    }
  }
}

void Gateway::signal_loop() {
  for (;;) {
    int signal = 0;
    if (::sigwait(&signal_set_, &signal) != 0) continue;
    if (signal == SIGTERM || signal == SIGINT || signal == SIGHUP) {
      log_event("shutdown_signal", log_field("signal", static_cast<uint64_t>(signal)));
      request_shutdown();
      server_.stop();
      return;
    }
    if (signal == SIGUSR1) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (shutting_down_) return;
    }
  }
}

void Gateway::request_shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_) return;
    shutting_down_ = true;
  }
  condition_.notify_all();
}

bool Gateway::send_backend_signal(pid_t pid, int signal, const char *event) {
  std::lock_guard<std::mutex> lock(mutex_);
  // Re-check immediately before kill.  The earlier check that selected the
  // action can be stale due to PID reuse or an argv/identity change.
  if (backend_pid_ != pid || !backend_is_safe_locked()) {
    log_event("backend_signal_rejected",
              log_field("pid", pid > 0 ? static_cast<uint64_t>(pid) : 0) +
                  log_field("reason", "identity_recheck_failed"));
    set_backoff_locked("identity_check_failed_before_signal");
    return false;
  }
  if (::kill(pid, signal) != 0) {
    log_event("backend_signal_failed",
              log_field("pid", static_cast<uint64_t>(pid)) +
                  log_field("errno", static_cast<uint64_t>(errno)));
    return false;
  }
  log_event(event, log_field("pid", static_cast<uint64_t>(pid)));
  return true;
}

void Gateway::join_threads() {
  if (supervisor_thread_.joinable()) supervisor_thread_.join();
  if (signal_thread_.joinable()) signal_thread_.join();
}

bool Gateway::write_gateway_pid_file() {
  const uint64_t current_pid = static_cast<uint64_t>(::getpid());
  const uint64_t current_start = process_start_epoch_ms(::getpid());
  if (current_start == 0) {
    log_event("gateway_pid_file_failed", log_field("reason", "zero_start_time"));
    return false;
  }
  for (int attempt = 0; attempt < 2; ++attempt) {
    const int fd = ::open(config_.gateway_pid_file.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd >= 0) {
      ::fchmod(fd, 0600);
      const std::string value = "pid=" + std::to_string(current_pid) + "\nstart_epoch_ms=" + std::to_string(current_start) + "\n";
      const bool ok = write_all(fd, value.data(), value.size());
      if (ok) ::fsync(fd);
      ::close(fd);
      if (ok) return true;
      ::unlink(config_.gateway_pid_file.c_str());
      return false;
    }
    if (errno != EEXIST || attempt != 0) return false;

    std::ifstream existing_file(config_.gateway_pid_file, std::ios::binary);
    const std::string existing((std::istreambuf_iterator<char>(existing_file)), std::istreambuf_iterator<char>());
    uint64_t old_pid = 0;
    uint64_t old_start = 0;
    bool has_start = false;
    if (!parse_pid_file_contents(existing, &old_pid, &old_start, &has_start) || old_pid == current_pid) {
      log_event("gateway_pid_file_occupied", log_field("reason", "unreadable_or_same_pid"));
      return false;
    }
    const bool zombie = process_is_zombie(static_cast<pid_t>(old_pid));
    const bool alive = process_alive(static_cast<pid_t>(old_pid));
    bool stale = zombie || !alive;
    if (!stale && has_start) {
      const uint64_t actual_start = process_start_epoch_ms(static_cast<pid_t>(old_pid));
      stale = actual_start != 0 && old_start != 0 && actual_start != old_start;
    }
    if (!stale) {
      log_event("gateway_pid_file_occupied", log_field("pid", old_pid));
      return false;
    }
    std::ifstream verify_file(config_.gateway_pid_file, std::ios::binary);
    const std::string verify((std::istreambuf_iterator<char>(verify_file)), std::istreambuf_iterator<char>());
    if (verify != existing || ::unlink(config_.gateway_pid_file.c_str()) != 0) return false;
    log_event("gateway_pid_file_stale_removed", log_field("pid", old_pid));
  }
  return false;
}

void Gateway::remove_gateway_pid_file() {
  std::ifstream existing_file(config_.gateway_pid_file, std::ios::binary);
  const std::string existing((std::istreambuf_iterator<char>(existing_file)), std::istreambuf_iterator<char>());
  uint64_t pid = 0;
  uint64_t start = 0;
  bool has_start = false;
  if (parse_pid_file_contents(existing, &pid, &start, &has_start) &&
      pid == static_cast<uint64_t>(::getpid())) {
    ::unlink(config_.gateway_pid_file.c_str());
  }
}

std::string Gateway::make_request_id() {
  return "req-" + std::to_string(unix_millis()) + "-" + std::to_string(request_counter_.fetch_add(1) + 1);
}

void Gateway::finish_request(const std::string &request_id, TimePoint started, int status) {
  const auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - started).count();
  std::lock_guard<std::mutex> lock(mutex_);
  request_deadlines_.erase(request_id);
  if (active_requests_ > 0) --active_requests_;
  if (active_requests_ == 0) last_request_finished_ = Clock::now();
  condition_.notify_all();
  log_event("request_finished", log_field("request_id", request_id) + log_field("latency_ms", static_cast<uint64_t>(duration < 0 ? 0 : duration)) + log_field("status", static_cast<uint64_t>(status)));
}

std::string Gateway::health_json_locked() const {
  uint64_t idle_remaining = 0;
  if (state_ == BackendState::Ready && active_requests_ == 0) {
    const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(Clock::now() - last_request_finished_).count();
    if (elapsed < config_.idle_timeout_seconds) idle_remaining = static_cast<uint64_t>(config_.idle_timeout_seconds - elapsed);
  }
  uint64_t backoff_remaining = 0;
  if (state_ == BackendState::Backoff && Clock::now() < backoff_until_) {
    backoff_remaining = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(backoff_until_ - Clock::now()).count());
  }
  std::ostringstream body;
  body << "{\"status\":\"ok\",\"mode\":\"" << kMode << "\",\"backend\":\"" << state_name(state_)
       << "\",\"active_requests\":" << active_requests_
       << ",\"pending_requests\":" << active_requests_
       << ",\"idle_remaining_seconds\":" << idle_remaining
       << ",\"backoff_remaining_seconds\":" << backoff_remaining;
  if (backend_pid_ > 0) body << ",\"pid\":" << backend_pid_;
  body << "}";
  return body.str();
}

std::string Gateway::ready_json_locked() const {
  std::ostringstream body;
  body << "{\"status\":\"" << (state_ == BackendState::Ready ? "ok" : "not_ready") << "\",\"backend\":\"" << state_name(state_) << "\"";
  if (state_ != BackendState::Ready && state_ == BackendState::Backoff) {
    const auto remaining = std::chrono::duration_cast<std::chrono::seconds>(backoff_until_ - Clock::now()).count();
    body << ",\"retry_after_seconds\":" << (remaining > 0 ? remaining : 1);
  }
  body << "}";
  return body.str();
}

void Gateway::handle_health(const Request &, Response &res) {
  std::lock_guard<std::mutex> lock(mutex_);
  set_json(res, 200, health_json_locked());
}

void Gateway::handle_ready(const Request &, Response &res) {
  std::lock_guard<std::mutex> lock(mutex_);
  const int status = state_ == BackendState::Ready ? 200 : 503;
  set_json(res, status, ready_json_locked());
  if (status != 200) {
    res.set_header("X-Request-Id", make_request_id());
    res.set_header("Connection", "close");
    res.set_header("Retry-After", "1");
  }
}

void Gateway::handle_options(const Request &, Response &res) {
  res.status = 204;
  set_cors(res);
}

bool Gateway::validate_request(const Request &req, Response &res) const {
  const std::string content_type = req.get_header_value("Content-Type");
  const auto separator = content_type.find(';');
  if (lower_copy(trim_copy(content_type.substr(0, separator))) != "multipart/form-data") {
    const_cast<Gateway *>(this)->set_error(res, 400, "Content-Type must be multipart/form-data");
    return false;
  }
  if (extract_boundary(content_type).empty()) {
    const_cast<Gateway *>(this)->set_error(res, 400, "multipart boundary is required");
    return false;
  }
  const std::string length = req.get_header_value("Content-Length");
  if (!length.empty()) {
    uint64_t content_length = 0;
    if (!parse_u64(length, &content_length)) {
      const_cast<Gateway *>(this)->set_error(res, 400, "invalid Content-Length");
      return false;
    }
    if (content_length > config_.max_upload_bytes) {
      const_cast<Gateway *>(this)->set_error(res, 413, "upload exceeds configured limit");
      res.set_header("Connection", "close");
      return false;
    }
  }
  return true;
}

void Gateway::set_error(Response &res, int status, const std::string &message, const std::string &retry_after) {
  set_json(res, status, "{\"error\":\"" + json_escape(message) + "\"}");
  if (!res.has_header("X-Request-Id")) res.set_header("X-Request-Id", make_request_id());
  // The body may not have been fully consumed (for example a rejected raw
  // upload or an unknown POST route), so never reuse this connection after an
  // error response.
  res.set_header("Connection", "close");
  if (!retry_after.empty()) res.set_header("Retry-After", retry_after);
}

bool Gateway::forward_file(const Request &req, const std::string &request_id,
                           const std::string &file_path, uint64_t file_size,
                           const std::string &content_type, TimePoint deadline,
                           Response &res) {
  Client client(config_.backend_host, config_.backend_port);
  if (!configure_client_deadline(client, deadline, std::chrono::milliseconds::zero())) {
    set_error(res, 502, "request deadline exceeded");
    return false;
  }
  Headers headers;
  headers.emplace("Accept", req.get_header_value("Accept", "application/json"));
  headers.emplace("X-Request-Id", request_id);
  std::ifstream file(file_path, std::ios::binary);
  if (!file) { set_error(res, 500, "cannot open staged upload"); return false; }
  auto provider = [&file, file_size, deadline](size_t offset, size_t length, DataSink &sink) -> bool {
    if (Clock::now() >= deadline) return false;
    if (offset >= file_size) return true;
    const size_t requested = std::min<uint64_t>(length, file_size - offset);
    file.clear();
    file.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!file) return false;
    std::string buffer(std::min<size_t>(requested, 1024 * 1024), '\0');
    size_t remaining = requested;
    while (remaining > 0) {
      if (Clock::now() >= deadline) return false;
      const size_t chunk = std::min(remaining, buffer.size());
      file.read(buffer.data(), static_cast<std::streamsize>(chunk));
      const std::streamsize got = file.gcount();
      if (got <= 0 || !sink.write(buffer.data(), static_cast<size_t>(got))) return false;
      remaining -= static_cast<size_t>(got);
    }
    return true;
  };
  auto result = client.Post(config_.inference_path, headers, static_cast<size_t>(file_size),
                            std::move(provider), content_type);
  if (!result) {
    set_error(res, 502, "backend request failed");
    return false;
  }
  res.status = result->status >= 100 && result->status <= 599 ? result->status : 502;
  std::string response_type = result->get_header_value("Content-Type", "application/json");
  res.set_content(result->body, response_type);
  res.set_header("X-Request-Id", request_id);
  set_cors(res);
  return true;
}

void Gateway::handle_post(const Request &req, Response &res, const ContentReader &reader) {
  const TimePoint started = Clock::now();
  const TimePoint deadline = started + std::chrono::seconds(config_.request_timeout_seconds);
  const std::string request_id = make_request_id();
  res.set_header("X-Request-Id", request_id);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_requests_ >= static_cast<size_t>(config_.max_pending_requests)) {
      set_error(res, 429, "too many transcription requests", "1");
      log_event("request_rejected", log_field("request_id", request_id) + log_field("status", 429));
      return;
    }
    ++active_requests_;
    request_deadlines_[request_id] = deadline;
  }
  int final_status = 500;
  auto request_scope = make_scope_exit([&]() {
    finish_request(request_id, started, final_status);
  });
  if (!validate_request(req, res)) { final_status = res.status; return; }

  TempUploadFile staged;
  if (!staged.create(config_.upload_dir)) {
    set_error(res, 500, "cannot create upload staging file");
    final_status = res.status;
    return;
  }
  bool write_ok = true;
  bool overflow = false;
  bool deadline_exceeded = false;
  bool client_disconnected = false;
  uint64_t staged_size = 0;
  const std::string content_type = req.get_header_value("Content-Type");
  auto append = [&](const char *data, size_t n) -> bool {
    if (n == 0) return true;
    if (Clock::now() >= deadline) {
      deadline_exceeded = true;
      return false;
    }
    if (req.is_connection_closed && req.is_connection_closed()) {
      client_disconnected = true;
      return false;
    }
    if (staged_size > config_.max_upload_bytes || n > config_.max_upload_bytes - staged_size) {
      overflow = true;
      return false;
    }
    if (!write_all(staged.fd(), data, n)) { write_ok = false; return false; }
    staged_size += n;
    return true;
  };
  bool reader_ok = false;
  {
    // The pinned httplib ContentReader's normal overload runs its multipart
    // parser.  Temporarily make that reader see an opaque body and invoke its
    // raw Reader member, which preserves every byte (including extra part
    // headers and multipart epilogues) while httplib still decodes chunked
    // transfer framing.  Restore all headers even if the receiver throws.
    Request &mutable_request = const_cast<Request &>(req);
    Headers original_headers = mutable_request.headers;
    auto restore_headers = make_scope_exit([&mutable_request,
                                            original_headers = std::move(original_headers)]() mutable {
      mutable_request.headers = std::move(original_headers);
    });
    mutable_request.headers.erase("Content-Type");
    mutable_request.headers.erase("Content-Encoding");
    mutable_request.set_header("Content-Type", "application/octet-stream");
    reader_ok = reader.reader_([&](const char *data, size_t n) -> bool {
      return append(data, n);
    });
  }
  if (Clock::now() >= deadline) deadline_exceeded = true;
  if (::fsync(staged.fd()) != 0) write_ok = false;
  if (!staged.close_fd()) write_ok = false;
  if (!reader_ok || overflow || !write_ok || deadline_exceeded || client_disconnected) {
    const bool payload_too_large = overflow || res.status == 413;
    const int status = payload_too_large ? 413 : (deadline_exceeded ? 503 : (write_ok ? 400 : 500));
    const std::string message = payload_too_large ? "upload exceeds configured limit" :
        (deadline_exceeded ? "request deadline exceeded" :
         (client_disconnected ? "client disconnected" :
          (write_ok ? "invalid multipart request" : "cannot stage upload")));
    set_error(res, status, message);
    final_status = res.status;
    return;
  }
  std::string reason;
  if (Clock::now() >= deadline) {
    set_error(res, 503, "request deadline exceeded");
    final_status = res.status;
    return;
  }
  if (!begin_backend(&reason)) {
    set_error(res, 503, reason, std::to_string(config_.start_failure_backoff_seconds));
    final_status = res.status;
    return;
  }
  if (!wait_until_ready(deadline, &reason)) {
    set_error(res, 503, reason, std::to_string(config_.start_failure_backoff_seconds));
    final_status = res.status;
    return;
  }
  forward_file(req, request_id, staged.path(), staged_size, content_type, deadline, res);
  const int status = res.status == -1 ? 500 : res.status;
  staged.unlink_path();
  final_status = status;
}

int Gateway::run() {
  sigemptyset(&signal_set_);
  sigaddset(&signal_set_, SIGTERM);
  sigaddset(&signal_set_, SIGINT);
  sigaddset(&signal_set_, SIGHUP);
  sigaddset(&signal_set_, SIGUSR1);
  ::pthread_sigmask(SIG_BLOCK, &signal_set_, nullptr);
  server_.set_payload_max_length(static_cast<size_t>(std::min<uint64_t>(config_.max_upload_bytes + 1024 * 1024, std::numeric_limits<size_t>::max())));
  server_.set_read_timeout(config_.request_timeout_seconds);
  server_.set_write_timeout(config_.request_timeout_seconds);
  server_.set_keep_alive_timeout(config_.request_timeout_seconds);
  server_.new_task_queue = [this] {
    const size_t limit = static_cast<size_t>(config_.max_pending_requests);
    // Keep one extra worker for health/ready and connection cleanup while all
    // transcription slots are occupied.  The bounded queue still limits
    // additional socket tasks and closes connections when it is full.
    const size_t workers = limit == (std::numeric_limits<size_t>::max)() ? limit : limit + 1;
    return static_cast<TaskQueue *>(new BoundedThreadPool(workers, limit));
  };
  server_.set_default_headers({{"Server", "whisper-on-demand"}});
  server_.set_pre_routing_handler([this](const Request &req, Response &res) {
    const bool allowed =
        (req.method == "GET" && (req.path == "/health" || req.path == "/ready")) ||
        (req.method == "OPTIONS" && req.path == config_.inference_path) ||
        (req.method == "POST" && req.path == config_.inference_path);
    if (allowed) return Server::HandlerResponse::Unhandled;
    set_error(res, 404, "not found");
    return Server::HandlerResponse::Handled;
  });
  server_.Get("/health", [this](const Request &req, Response &res) { handle_health(req, res); });
  server_.Get("/ready", [this](const Request &req, Response &res) { handle_ready(req, res); });
  server_.Options(config_.inference_path, [this](const Request &req, Response &res) { handle_options(req, res); });
  server_.Post(config_.inference_path, [this](const Request &req, Response &res, const ContentReader &reader) { handle_post(req, res, reader); });
  server_.set_error_handler([this](const Request &, Response &res) {
    if (res.body.empty() && (res.status == -1 || res.status == 404)) {
      set_json(res, 404, "{\"error\":\"not found\"}");
    } else if (res.body.empty() && res.status == 405) {
      set_json(res, 405, "{\"error\":\"method not allowed\"}");
    } else if (res.body.empty()) {
      set_json(res, res.status > 0 ? res.status : 500, "{\"error\":\"request failed\"}");
    } else {
      set_cors(res);
    }
    if (res.status >= 400) {
      if (!res.has_header("X-Request-Id")) res.set_header("X-Request-Id", make_request_id());
      res.set_header("Connection", "close");
    }
    return true;
  });
  server_.set_logger([](const Request &, const Response &) {});
  if (!write_gateway_pid_file()) {
    std::fprintf(stderr, "错误：无法安全写入网关 PID 文件：%s\n", config_.gateway_pid_file.c_str());
    return 1;
  }
  // Bind before adopting a backend.  If an unknown process owns the public
  // port, this instance exits without touching an otherwise valid backend
  // belonging to a different gateway.
  if (!server_.bind_to_port(config_.gateway_host, config_.gateway_port)) {
    std::fprintf(stderr, "错误：网关端口无法绑定：%s:%d\n", config_.gateway_host.c_str(), config_.gateway_port);
    remove_gateway_pid_file();
    return 1;
  }
  supervisor_thread_ = std::thread([this] { supervisor_loop(); });
  signal_thread_ = std::thread([this] { signal_loop(); });
  adopt_backend_if_safe();
  log_event("gateway_listening", log_field("host", config_.gateway_host) + log_field("port", static_cast<uint64_t>(config_.gateway_port)));
  const bool listened = server_.listen_after_bind();
  request_shutdown();
  condition_.notify_all();
  if (signal_thread_.joinable()) {
    ::pthread_kill(signal_thread_.native_handle(), SIGUSR1);
  }
  if (supervisor_thread_.joinable()) supervisor_thread_.join();
  if (signal_thread_.joinable()) signal_thread_.join();
  remove_gateway_pid_file();
  return listened ? 0 : 1;
}

} // namespace

int main(int argc, char **argv) {
  Config config;
  std::string error;
  if (!parse_args(argc, argv, &config, &error)) {
    std::fprintf(stderr, "错误：%s\n", error.c_str());
    print_help(argv[0]);
    return kExitUsage;
  }
  Gateway gateway(std::move(config));
  if (!gateway.validate_startup(&error)) {
    std::fprintf(stderr, "错误：%s\n", error.c_str());
    return kExitConfiguration;
  }
  return gateway.run();
}
