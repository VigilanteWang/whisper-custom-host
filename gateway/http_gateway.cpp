#include "http_gateway.h"

#include "platform_process.h"
#include "support.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
#include <utility>

#include <cerrno>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

namespace whisper_gateway {
namespace {

constexpr const char *kMode = "on-demand";

} // namespace

HttpGateway::HttpGateway(Config config) : controller_(std::move(config)) {}

HttpGateway::~HttpGateway() {
  server_.stop();
  controller_.request_shutdown();
  if (signal_thread_.joinable()) {
    (void)::pthread_kill(signal_thread_.native_handle(), SIGUSR1);
    signal_thread_.join();
  }
  controller_.join();
}

bool HttpGateway::validate_startup(std::string *error) {
  return controller_.validate_startup(error);
}

std::string HttpGateway::make_request_id() {
  return "req-" + std::to_string(unix_millis()) + "-" +
         std::to_string(request_counter_.fetch_add(1) + 1);
}

void HttpGateway::set_error(httplib::Response &response, int status,
                            const std::string &message,
                            const std::string &retry_after) {
  set_json(response, status,
           "{\"error\":\"" + json_escape(message) + "\"}");
  if (!response.has_header("X-Request-Id")) {
    response.set_header("X-Request-Id", make_request_id());
  }
  response.set_header("Connection", "close");
  if (!retry_after.empty()) response.set_header("Retry-After", retry_after);
}

void HttpGateway::handle_health(const httplib::Request &,
                                httplib::Response &response) {
  const BackendSnapshot snapshot = controller_.snapshot();
  std::ostringstream body;
  body << "{\"status\":\"ok\",\"mode\":\"" << kMode
       << "\",\"backend\":\"" << state_name(snapshot.state)
       << "\",\"active_requests\":" << snapshot.active_requests
       << ",\"pending_requests\":" << snapshot.active_requests
       << ",\"idle_remaining_seconds\":"
       << snapshot.idle_remaining_seconds
       << ",\"backoff_remaining_seconds\":"
       << snapshot.backoff_remaining_seconds;
  if (snapshot.pid > 0) body << ",\"pid\":" << snapshot.pid;
  body << "}";
  set_json(response, 200, body.str());
}

void HttpGateway::handle_ready(const httplib::Request &,
                               httplib::Response &response) {
  const BackendSnapshot snapshot = controller_.snapshot();
  const bool ready = snapshot.state == BackendState::Ready;
  std::ostringstream body;
  body << "{\"status\":\"" << (ready ? "ok" : "not_ready")
       << "\",\"backend\":\"" << state_name(snapshot.state) << "\"";
  if (snapshot.state == BackendState::Backoff) {
    body << ",\"retry_after_seconds\":"
         << std::max<std::uint64_t>(snapshot.backoff_remaining_seconds, 1);
  }
  body << "}";
  set_json(response, ready ? 200 : 503, body.str());
  if (!ready) {
    response.set_header("X-Request-Id", make_request_id());
    response.set_header("Connection", "close");
    response.set_header("Retry-After", "1");
  }
}

void HttpGateway::handle_options(const httplib::Request &,
                                 httplib::Response &response) {
  response.status = 204;
  set_cors(response);
}

bool HttpGateway::validate_request(const httplib::Request &request,
                                   httplib::Response &response) {
  const std::string content_type = request.get_header_value("Content-Type");
  const auto separator = content_type.find(';');
  if (lower_copy(trim_copy(content_type.substr(0, separator))) !=
      "multipart/form-data") {
    set_error(response, 400,
              "Content-Type must be multipart/form-data");
    return false;
  }
  if (extract_boundary(content_type).empty()) {
    set_error(response, 400, "multipart boundary is required");
    return false;
  }
  const std::string length = request.get_header_value("Content-Length");
  const std::string transfer_encoding =
      request.get_header_value("Transfer-Encoding");
  // A request carrying both headers is ambiguous and must not take the
  // known-length fast path.  Reject it before invoking the ContentReader so
  // an attacker cannot advertise a tiny Content-Length while sending an
  // oversized chunked body and force an unnecessary backend start.
  if (!length.empty() && !transfer_encoding.empty()) {
    set_error(response, 400,
              "Content-Length cannot be combined with Transfer-Encoding");
    return false;
  }
  if (!length.empty()) {
    std::uint64_t content_length = 0;
    if (!parse_u64(length, &content_length)) {
      set_error(response, 400, "invalid Content-Length");
      return false;
    }
    if (content_length > controller_.config().max_upload_bytes) {
      set_error(response, 413, "upload exceeds configured limit");
      return false;
    }
  }
  return true;
}

bool HttpGateway::forward_file(const httplib::Request &request,
                               const std::string &request_id,
                               const std::string &file_path,
                               std::uint64_t file_size,
                               const std::string &content_type,
                               TimePoint deadline,
                               httplib::Response &response) {
  const Config &config = controller_.config();
  httplib::Client client(config.backend_host, config.backend_port);
  if (!configure_client_deadline(client, deadline,
                                 std::chrono::milliseconds::zero())) {
    set_error(response, 502, "request deadline exceeded");
    return false;
  }
  httplib::Headers headers;
  headers.emplace("Accept",
                  request.get_header_value("Accept", "application/json"));
  headers.emplace("X-Request-Id", request_id);
  std::ifstream file(file_path, std::ios::binary);
  if (!file) {
    set_error(response, 500, "cannot open staged upload");
    return false;
  }
  auto provider = [&file, file_size,
                   deadline](std::size_t offset, std::size_t length,
                             httplib::DataSink &sink) -> bool {
    if (Clock::now() >= deadline || offset >= file_size) {
      return offset >= file_size;
    }
    const auto available = file_size - static_cast<std::uint64_t>(offset);
    const std::size_t requested = static_cast<std::size_t>(
        std::min<std::uint64_t>(static_cast<std::uint64_t>(length),
                                available));
    file.clear();
    file.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!file) return false;
    std::string buffer(std::min<std::size_t>(requested, 1024U * 1024U),
                       '\0');
    std::size_t remaining = requested;
    while (remaining > 0) {
      if (Clock::now() >= deadline) return false;
      const std::size_t chunk = std::min(remaining, buffer.size());
      file.read(buffer.data(), static_cast<std::streamsize>(chunk));
      const std::streamsize got = file.gcount();
      if (got <= 0 ||
          !sink.write(buffer.data(), static_cast<std::size_t>(got))) {
        return false;
      }
      remaining -= static_cast<std::size_t>(got);
    }
    return true;
  };
  auto result = client.Post(config.inference_path, headers,
                            static_cast<std::size_t>(file_size),
                            std::move(provider), content_type);
  if (!result) {
    set_error(response, 502, "backend request failed");
    return false;
  }
  response.status = result->status >= 100 && result->status <= 599
                        ? result->status
                        : 502;
  response.set_content(
      result->body,
      result->get_header_value("Content-Type", "application/json"));
  response.set_header("X-Request-Id", request_id);
  set_cors(response);
  return true;
}

void HttpGateway::handle_post(const httplib::Request &request,
                              httplib::Response &response,
                              const httplib::ContentReader &reader) {
  const Config &config = controller_.config();
  const TimePoint started = Clock::now();
  const TimePoint deadline =
      started + std::chrono::seconds(config.request_timeout_seconds);
  const std::string request_id = make_request_id();
  response.set_header("X-Request-Id", request_id);

  auto lease = controller_.acquire_request(request_id, started, deadline);
  if (!lease) {
    set_error(response, 429, "too many transcription requests", "1");
    log_event("request_rejected",
              log_field("request_id", request_id) +
                  log_field("status", static_cast<std::uint64_t>(429)));
    return;
  }
  int final_status = 500;
  auto finish_lease = make_scope_exit([&] { lease->finish(final_status); });

  if (!validate_request(request, response)) {
    final_status = response.status;
    return;
  }

  TempUploadFile staged;
  if (!staged.create(config.upload_dir)) {
    set_error(response, 500, "cannot create upload staging file");
    final_status = response.status;
    return;
  }

  const std::string content_length_header =
      request.get_header_value("Content-Length");
  std::uint64_t content_length = 0;
  const bool known_legal_length =
      !content_length_header.empty() &&
      parse_u64(content_length_header, &content_length) &&
      content_length > 0 && content_length <= config.max_upload_bytes;
  std::string reason;
  if (known_legal_length && !controller_.begin_backend(&reason)) {
    set_error(response, 503, reason,
              std::to_string(config.start_failure_backoff_seconds));
    final_status = response.status;
    return;
  }

  bool write_ok = true;
  bool overflow = false;
  bool deadline_exceeded = false;
  bool client_disconnected = false;
  std::uint64_t staged_size = 0;
  const std::string content_type = request.get_header_value("Content-Type");
  auto append = [&](const char *data, std::size_t size) -> bool {
    if (size == 0) return true;
    if (Clock::now() >= deadline) {
      deadline_exceeded = true;
      return false;
    }
    if (request.is_connection_closed && request.is_connection_closed()) {
      client_disconnected = true;
      return false;
    }
    if (staged_size > config.max_upload_bytes ||
        static_cast<std::uint64_t>(size) >
            config.max_upload_bytes - staged_size) {
      overflow = true;
      return false;
    }
    if (!write_all(staged.fd(), data, size)) {
      write_ok = false;
      return false;
    }
    staged_size += static_cast<std::uint64_t>(size);
    return true;
  };

  // The pinned ContentReader exposes a public raw ContentReceiver overload.
  // It preserves multipart bytes while httplib still removes chunk framing.
  bool reader_ok = false;
  try {
    reader_ok = reader(append);
  } catch (const std::exception &error) {
    log_event("request_upload_exception",
              log_field("request_id", request_id) +
                  log_field("what", error.what()));
    write_ok = false;
  }
  if (request.is_connection_closed && request.is_connection_closed()) {
    client_disconnected = true;
  }
  if (Clock::now() >= deadline) deadline_exceeded = true;
  if (::fsync(staged.fd()) != 0) write_ok = false;
  if (!staged.close_fd()) write_ok = false;
  if (!reader_ok || overflow || !write_ok || deadline_exceeded ||
      client_disconnected) {
    const int status = overflow ? 413 : (deadline_exceeded ? 503
                                                           : (write_ok ? 400
                                                                       : 500));
    const std::string message =
        overflow
            ? "upload exceeds configured limit"
            : (deadline_exceeded
                   ? "request deadline exceeded"
                   : (client_disconnected
                          ? "client disconnected"
                          : (write_ok ? "invalid multipart request"
                                      : "cannot stage upload")));
    set_error(response, status, message);
    final_status = response.status;
    return;
  }

  // The client may have closed the socket immediately after the final body
  // bytes were read.  Do not start or wait for the backend for a request that
  // can no longer receive a response.
  if (request.is_connection_closed && request.is_connection_closed()) {
    set_error(response, 400, "client disconnected");
    final_status = response.status;
    return;
  }
  if (!known_legal_length && !controller_.begin_backend(&reason)) {
    set_error(response, 503, reason,
              std::to_string(config.start_failure_backoff_seconds));
    final_status = response.status;
    return;
  }
  if (request.is_connection_closed && request.is_connection_closed()) {
    set_error(response, 400, "client disconnected");
    final_status = response.status;
    return;
  }
  if (!controller_.wait_until_ready(deadline, &reason)) {
    set_error(response, 503, reason,
              std::to_string(config.start_failure_backoff_seconds));
    final_status = response.status;
    return;
  }
  if (request.is_connection_closed && request.is_connection_closed()) {
    set_error(response, 400, "client disconnected");
    final_status = response.status;
    return;
  }
  (void)forward_file(request, request_id, staged.path(), staged_size,
                     content_type, deadline, response);
  final_status = response.status == -1 ? 500 : response.status;
  (void)staged.unlink_path();
}

bool HttpGateway::write_gateway_pid_file() {
  const std::uint64_t current_pid = static_cast<std::uint64_t>(::getpid());
  const std::uint64_t current_start = process_start_epoch_ms(::getpid());
  if (current_start == 0) {
    log_event("gateway_pid_file_failed", log_field("reason", "zero_start_time"));
    return false;
  }
  const std::string &pid_file = controller_.config().gateway_pid_file;
  for (int attempt = 0; attempt < 2; ++attempt) {
    const int fd =
        ::open(pid_file.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
               0600);
    if (fd >= 0) {
      (void)::fchmod(fd, 0600);
      const std::string value =
          "pid=" + std::to_string(current_pid) + "\nstart_epoch_ms=" +
          std::to_string(current_start) + "\n";
      const bool ok = write_all(fd, value.data(), value.size());
      if (ok) (void)::fsync(fd);
      (void)::close(fd);
      if (ok) return true;
      (void)::unlink(pid_file.c_str());
      return false;
    }
    if (errno != EEXIST || attempt != 0) return false;

    std::ifstream existing_file(pid_file, std::ios::binary);
    const std::string existing((std::istreambuf_iterator<char>(existing_file)),
                               std::istreambuf_iterator<char>());
    std::uint64_t old_pid = 0;
    std::uint64_t old_start = 0;
    bool has_start = false;
    if (!parse_pid_file_contents(existing, &old_pid, &old_start, &has_start) ||
        old_pid == current_pid) {
      log_event("gateway_pid_file_occupied",
                log_field("reason", "unreadable_or_same_pid"));
      return false;
    }
    const bool zombie = process_is_zombie(static_cast<pid_t>(old_pid));
    const bool alive = process_alive(static_cast<pid_t>(old_pid));
    bool stale = zombie || !alive;
    if (!stale && has_start) {
      const std::uint64_t actual_start =
          process_start_epoch_ms(static_cast<pid_t>(old_pid));
      stale = actual_start != 0 && old_start != 0 && actual_start != old_start;
    }
    if (!stale) {
      log_event("gateway_pid_file_occupied", log_field("pid", old_pid));
      return false;
    }
    std::ifstream verify_file(pid_file, std::ios::binary);
    const std::string verify((std::istreambuf_iterator<char>(verify_file)),
                             std::istreambuf_iterator<char>());
    if (verify != existing || ::unlink(pid_file.c_str()) != 0) return false;
    log_event("gateway_pid_file_stale_removed", log_field("pid", old_pid));
  }
  return false;
}

void HttpGateway::remove_gateway_pid_file() {
  const std::string &pid_file = controller_.config().gateway_pid_file;
  std::ifstream existing_file(pid_file, std::ios::binary);
  const std::string existing((std::istreambuf_iterator<char>(existing_file)),
                             std::istreambuf_iterator<char>());
  std::uint64_t pid = 0;
  std::uint64_t start = 0;
  bool has_start = false;
  if (parse_pid_file_contents(existing, &pid, &start, &has_start) &&
      pid == static_cast<std::uint64_t>(::getpid())) {
    (void)::unlink(pid_file.c_str());
  }
}

void HttpGateway::signal_loop() {
  for (;;) {
    int signal = 0;
    if (::sigwait(&signal_set_, &signal) != 0) continue;
    if (signal == SIGTERM || signal == SIGINT || signal == SIGHUP) {
      log_event("shutdown_signal",
                log_field("signal", static_cast<std::uint64_t>(signal)));
      controller_.request_shutdown();
      server_.stop();
      return;
    }
    if (signal == SIGUSR1) return;
  }
}

int HttpGateway::run() {
  const Config &config = controller_.config();
  (void)sigemptyset(&signal_set_);
  (void)sigaddset(&signal_set_, SIGTERM);
  (void)sigaddset(&signal_set_, SIGINT);
  (void)sigaddset(&signal_set_, SIGHUP);
  (void)sigaddset(&signal_set_, SIGUSR1);
  (void)::pthread_sigmask(SIG_BLOCK, &signal_set_, nullptr);

  server_.set_payload_max_length(
      static_cast<std::size_t>(config.max_payload_bytes));
  server_.set_read_timeout(config.request_timeout_seconds);
  server_.set_write_timeout(config.request_timeout_seconds);
  server_.set_keep_alive_timeout(config.request_timeout_seconds);
  server_.new_task_queue = [&config] {
    const auto limit =
        static_cast<std::size_t>(config.max_pending_requests);
    const std::size_t workers = limit + 1;
    return static_cast<httplib::TaskQueue *>(
        new BoundedThreadPool(workers, limit));
  };
  server_.set_default_headers({{"Server", "whisper-on-demand"}});
  server_.set_pre_routing_handler(
      [this, &config](const httplib::Request &request,
                      httplib::Response &response) {
        const bool allowed =
            (request.method == "GET" &&
             (request.path == "/health" || request.path == "/ready")) ||
            (request.method == "OPTIONS" &&
             request.path == config.inference_path) ||
            (request.method == "POST" &&
             request.path == config.inference_path);
        if (allowed) return httplib::Server::HandlerResponse::Unhandled;
        set_error(response, 404, "not found");
        return httplib::Server::HandlerResponse::Handled;
      });
  server_.Get("/health", [this](const auto &request, auto &response) {
    handle_health(request, response);
  });
  server_.Get("/ready", [this](const auto &request, auto &response) {
    handle_ready(request, response);
  });
  server_.Options(config.inference_path,
                  [this](const auto &request, auto &response) {
                    handle_options(request, response);
                  });
  server_.Post(config.inference_path,
               [this](const httplib::Request &request,
                      httplib::Response &response,
                      const httplib::ContentReader &reader) {
                 handle_post(request, response, reader);
               });
  server_.set_error_handler(
      [this](const httplib::Request &, httplib::Response &response) {
        if (response.body.empty() &&
            (response.status == -1 || response.status == 404)) {
          set_json(response, 404, "{\"error\":\"not found\"}");
        } else if (response.body.empty() && response.status == 405) {
          set_json(response, 405,
                   "{\"error\":\"method not allowed\"}");
        } else if (response.body.empty()) {
          set_json(response, response.status > 0 ? response.status : 500,
                   "{\"error\":\"request failed\"}");
        } else {
          set_cors(response);
        }
        if (response.status >= 400) {
          if (!response.has_header("X-Request-Id")) {
            response.set_header("X-Request-Id", make_request_id());
          }
          response.set_header("Connection", "close");
        }
        return true;
      });
  server_.set_logger([](const auto &, const auto &) {});

  if (!write_gateway_pid_file()) {
    std::fprintf(stderr, "错误：无法安全写入网关 PID 文件：%s\n",
                 config.gateway_pid_file.c_str());
    return 1;
  }
  if (!server_.bind_to_port(config.gateway_host, config.gateway_port)) {
    std::fprintf(stderr, "错误：网关端口无法绑定：%s:%d\n",
                 config.gateway_host.c_str(), config.gateway_port);
    remove_gateway_pid_file();
    return 1;
  }
  controller_.start();
  signal_thread_ = std::thread([this] { signal_loop(); });
  log_event("gateway_listening",
            log_field("host", config.gateway_host) +
                log_field("port",
                          static_cast<std::uint64_t>(config.gateway_port)));
  const bool listened = server_.listen_after_bind();
  controller_.request_shutdown();
  if (signal_thread_.joinable()) {
    (void)::pthread_kill(signal_thread_.native_handle(), SIGUSR1);
  }
  controller_.join();
  if (signal_thread_.joinable()) signal_thread_.join();
  remove_gateway_pid_file();
  return listened ? 0 : 1;
}

} // namespace whisper_gateway
