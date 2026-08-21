// Minimal raw HTTP fixture for multipart pass-through regression tests.
//
// The normal mock uses the pinned httplib multipart parser.  This fixture uses
// a small socket reader so the test can compare the exact body received from
// the gateway, including boundary syntax and non-standard part headers.

#include <arpa/inet.h>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <mutex>
#include <netinet/in.h>
#include <pthread.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

struct Options {
  std::string host = "127.0.0.1";
  int port = 18080;
  std::string inference_path = "/v1/audio/transcriptions";
  std::string marker_file;
  std::string body_file;
  std::string headers_file;
};

std::atomic<bool> g_terminating{false};
std::atomic<int> g_listen_fd{-1};
std::mutex g_marker_mutex;

std::string env_string(const char *name, const std::string &fallback = {}) {
  const char *value = std::getenv(name);
  return value == nullptr ? fallback : std::string(value);
}

int parse_int(const std::string &value, const char *name) {
  char *end = nullptr;
  errno = 0;
  const long parsed = std::strtol(value.c_str(), &end, 10);
  if (end == value.c_str() || *end != '\0' || errno == ERANGE || parsed < 1 || parsed > 65535) {
    throw std::runtime_error(std::string("invalid ") + name + ": " + value);
  }
  return static_cast<int>(parsed);
}

void marker(const Options &options, const std::string &event) {
  if (options.marker_file.empty()) return;
  std::lock_guard<std::mutex> lock(g_marker_mutex);
  std::ofstream out(options.marker_file, std::ios::app);
  if (out) {
    out << event << '\n';
    out.flush();
  }
}

bool write_all(int fd, const char *data, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    const ssize_t written = ::write(fd, data + offset, length - offset);
    if (written > 0) {
      offset += static_cast<size_t>(written);
      continue;
    }
    if (written < 0 && errno == EINTR) continue;
    return false;
  }
  return true;
}

bool send_all(int fd, const std::string &value) {
  return write_all(fd, value.data(), value.size());
}

bool capture_file(const std::string &path, const std::string &value) {
  if (path.empty()) return true;
  const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return false;
  ::fchmod(fd, 0600);
  const bool ok = write_all(fd, value.data(), value.size());
  ::close(fd);
  return ok;
}

bool capture_file(const std::string &path, const std::vector<char> &value) {
  if (path.empty()) return true;
  const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return false;
  ::fchmod(fd, 0600);
  const bool ok = write_all(fd, value.data(), value.size());
  ::close(fd);
  return ok;
}

std::string lower_copy(std::string value) {
  for (char &character : value) {
    character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
  }
  return value;
}

std::string header_value(const std::string &headers, const std::string &wanted) {
  const std::string wanted_lower = lower_copy(wanted);
  size_t line_begin = 0;
  while (line_begin < headers.size()) {
    const size_t line_end = headers.find("\r\n", line_begin);
    if (line_end == std::string::npos) break;
    const size_t colon = headers.find(':', line_begin);
    if (colon != std::string::npos && colon < line_end &&
        lower_copy(headers.substr(line_begin, colon - line_begin)) == wanted_lower) {
      size_t value_begin = colon + 1;
      while (value_begin < line_end && (headers[value_begin] == ' ' || headers[value_begin] == '\t')) ++value_begin;
      return headers.substr(value_begin, line_end - value_begin);
    }
    line_begin = line_end + 2;
  }
  return {};
}

bool parse_size(const std::string &value, size_t *result) {
  if (value.empty()) return false;
  uint64_t parsed = 0;
  for (const char character : value) {
    if (character < '0' || character > '9') return false;
    const uint64_t digit = static_cast<uint64_t>(character - '0');
    if (parsed > (UINT64_MAX - digit) / 10) return false;
    parsed = parsed * 10 + digit;
  }
  if (parsed > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) return false;
  *result = static_cast<size_t>(parsed);
  return true;
}

bool read_request(int fd, std::string *header_block, std::vector<char> *body) {
  std::string buffer;
  buffer.reserve(8192);
  char chunk[4096];
  size_t header_end = std::string::npos;
  while ((header_end = buffer.find("\r\n\r\n")) == std::string::npos) {
    if (buffer.size() > 65536) return false;
    const ssize_t received = ::read(fd, chunk, sizeof(chunk));
    if (received <= 0) return false;
    buffer.append(chunk, static_cast<size_t>(received));
  }
  header_end += 4;
  *header_block = buffer.substr(0, header_end);
  const std::string length_text = header_value(*header_block, "Content-Length");
  size_t body_length = 0;
  if (!length_text.empty() && !parse_size(length_text, &body_length)) return false;
  if (body_length > 1024ULL * 1024ULL * 1024ULL) return false;

  body->assign(buffer.begin() + static_cast<std::ptrdiff_t>(header_end), buffer.end());
  while (body->size() < body_length) {
    const ssize_t received = ::read(fd, chunk, sizeof(chunk));
    if (received <= 0) return false;
    body->insert(body->end(), chunk, chunk + received);
  }
  if (body->size() > body_length) body->resize(body_length);
  return true;
}

void send_json(int fd, int status, const std::string &body) {
  const char *reason = status == 200 ? "OK" : status == 204 ? "No Content" : status == 400 ? "Bad Request" : "Not Found";
  std::ostringstream response;
  response << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
           << "Content-Type: application/json\r\n"
           << "Content-Length: " << body.size() << "\r\n"
           << "Access-Control-Allow-Origin: *\r\n"
           << "Connection: close\r\n\r\n" << body;
  (void)send_all(fd, response.str());
}

void send_options(int fd) {
  (void)send_all(fd,
                 "HTTP/1.1 204 No Content\r\n"
                 "Access-Control-Allow-Origin: *\r\n"
                 "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
                 "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
                 "Content-Length: 0\r\nConnection: close\r\n\r\n");
}

void handle_connection(int fd, const Options &options) {
  std::string headers;
  std::vector<char> body;
  if (!read_request(fd, &headers, &body)) {
    send_json(fd, 400, "{\"error\":\"bad request\"}");
    return;
  }
  const size_t request_line_end = headers.find("\r\n");
  if (request_line_end == std::string::npos) {
    send_json(fd, 400, "{\"error\":\"bad request\"}");
    return;
  }
  const std::string request_line = headers.substr(0, request_line_end);
  std::istringstream request_stream(request_line);
  std::string method;
  std::string path;
  request_stream >> method >> path;
  if (method == "GET" && path == "/health") {
    send_json(fd, 200, "{\"status\":\"ok\"}");
    return;
  }
  if (method == "OPTIONS" && path == options.inference_path) {
    send_options(fd);
    return;
  }
  if (method != "POST" || path != options.inference_path) {
    send_json(fd, 404, "{\"error\":\"not found\"}");
    return;
  }

  (void)capture_file(options.headers_file, headers);
  (void)capture_file(options.body_file, body);
  marker(options, "body-bytes " + std::to_string(body.size()));
  const std::string request_id = header_value(headers, "X-Request-Id");
  if (!request_id.empty()) marker(options, "request-id " + request_id);
  send_json(fd, 200, "{\"text\":\"raw mock transcription\"}");
}

void parse_args(int argc, char **argv, Options *options) {
  options->host = env_string("MOCK_HOST", options->host);
  options->inference_path = env_string("MOCK_INFERENCE_PATH", options->inference_path);
  options->marker_file = env_string("MOCK_MARKER_FILE");
  options->body_file = env_string("MOCK_CAPTURE_BODY_FILE");
  options->headers_file = env_string("MOCK_CAPTURE_HEADERS_FILE");
  const char *port_env = std::getenv("MOCK_PORT");
  if (port_env != nullptr) options->port = parse_int(port_env, "MOCK_PORT");
  for (int index = 1; index < argc; ++index) {
    const std::string arg = argv[index];
    if (arg == "--host" && index + 1 < argc) options->host = argv[++index];
    else if (arg == "--port" && index + 1 < argc) options->port = parse_int(argv[++index], "--port");
    else if (arg == "--inference-path" && index + 1 < argc) options->inference_path = argv[++index];
  }
  if (options->inference_path.empty() || options->inference_path.front() != '/') {
    throw std::runtime_error("inference path must start with '/'");
  }
}

void signal_loop(const sigset_t &signal_set, int *listen_fd) {
  int signal = 0;
  if (::sigwait(&signal_set, &signal) != 0) return;
  if (signal == SIGUSR1) return;
  g_terminating.store(true);
  const int fd = *listen_fd;
  if (fd >= 0) {
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
    g_listen_fd.store(-1);
  }
}

}  // namespace

int main(int argc, char **argv) {
  Options options;
  try {
    parse_args(argc, argv, &options);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "mock-raw-whisper-server: %s\n", error.what());
    return 2;
  }
  marker(options, "start");

  sigset_t signal_set;
  sigemptyset(&signal_set);
  sigaddset(&signal_set, SIGTERM);
  sigaddset(&signal_set, SIGINT);
  sigaddset(&signal_set, SIGHUP);
  sigaddset(&signal_set, SIGUSR1);
  ::pthread_sigmask(SIG_BLOCK, &signal_set, nullptr);

  const int listen_fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (listen_fd < 0) return 1;
  int reuse = 1;
  (void)::setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(options.port));
  if (::inet_pton(AF_INET, options.host.c_str(), &address.sin_addr) != 1 ||
      ::bind(listen_fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
      ::listen(listen_fd, 32) != 0) {
    ::close(listen_fd);
    return 1;
  }
  g_listen_fd.store(listen_fd);
  int signal_fd = listen_fd;
  std::thread signal_thread(signal_loop, std::cref(signal_set), &signal_fd);

  while (!g_terminating.load()) {
    fd_set read_set;
    FD_ZERO(&read_set);
    FD_SET(listen_fd, &read_set);
    timeval timeout{0, 100000};
    const int selected = ::select(listen_fd + 1, &read_set, nullptr, nullptr, &timeout);
    if (selected < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (selected == 0) continue;
    const int client_fd = ::accept(listen_fd, nullptr, nullptr);
    if (client_fd < 0) {
      if (g_terminating.load()) break;
      if (errno == EINTR) continue;
      break;
    }
    handle_connection(client_fd, options);
    ::shutdown(client_fd, SHUT_RDWR);
    ::close(client_fd);
  }

  g_terminating.store(true);
  ::shutdown(listen_fd, SHUT_RDWR);
  ::close(listen_fd);
  g_listen_fd.store(-1);
  ::pthread_kill(signal_thread.native_handle(), SIGUSR1);
  signal_thread.join();
  marker(options, "stop");
  return 0;
}
