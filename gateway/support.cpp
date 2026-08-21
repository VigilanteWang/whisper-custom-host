#include "support.h"

#include <CommonCrypto/CommonDigest.h>

#include <cctype>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <exception>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>
#include <unordered_map>

#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

namespace whisper_gateway {

uint64_t unix_millis() {
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(now).count());
}

bool deadline_expired(const TimePoint deadline) {
  return deadline != TimePoint::max() && Clock::now() >= deadline;
}

bool configure_client_deadline(httplib::Client &client,
                               const TimePoint deadline,
                               const std::chrono::milliseconds maximum) {
  if (maximum.count() < 0) return false;

  std::chrono::milliseconds remaining;
  if (deadline == TimePoint::max()) {
    if (maximum.count() <= 0) return false;
    remaining = maximum;
  } else {
    const auto now = Clock::now();
    if (now >= deadline) return false;
    remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline - now);
    // A positive timeout is required by cpp-httplib even when the deadline is
    // less than one millisecond away after duration truncation.
    if (remaining.count() <= 0) remaining = std::chrono::milliseconds(1);
    if (maximum.count() > 0 && remaining > maximum) remaining = maximum;
  }
  if (remaining.count() <= 0) return false;

  client.set_connection_timeout(remaining);
  client.set_read_timeout(remaining);
  client.set_write_timeout(remaining);
  client.set_max_timeout(remaining);
  return true;
}

std::string json_escape(const std::string &value) {
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (const char raw : value) {
    const unsigned char character = static_cast<unsigned char>(raw);
    switch (character) {
    case '"': escaped += "\\\""; break;
    case '\\': escaped += "\\\\"; break;
    case '\n': escaped += "\\n"; break;
    case '\r': escaped += "\\r"; break;
    case '\t': escaped += "\\t"; break;
    default:
      if (character < 0x20U) {
        char buffer[7];
        std::snprintf(buffer, sizeof(buffer), "\\u%04x",
                      static_cast<unsigned int>(character));
        escaped += buffer;
      } else {
        escaped += static_cast<char>(character);
      }
    }
  }
  return escaped;
}

std::string json_quote(const std::string &value) {
  return "\"" + json_escape(value) + "\"";
}

std::string lower_copy(std::string value) {
  for (char &raw : value) {
    raw = static_cast<char>(std::tolower(static_cast<unsigned char>(raw)));
  }
  return value;
}

std::string trim_copy(std::string value) {
  const auto is_space = [](const unsigned char character) {
    return std::isspace(character) != 0;
  };
  while (!value.empty() &&
         is_space(static_cast<unsigned char>(value.front()))) {
    value.erase(value.begin());
  }
  while (!value.empty() &&
         is_space(static_cast<unsigned char>(value.back()))) {
    value.pop_back();
  }
  return value;
}

bool parse_u64(const std::string_view value, uint64_t *out) {
  if (out == nullptr || value.empty()) return false;
  uint64_t result = 0;
  for (const char raw : value) {
    const unsigned char character = static_cast<unsigned char>(raw);
    if (std::isdigit(character) == 0) return false;
    const uint64_t digit = static_cast<uint64_t>(character - '0');
    if (result > (std::numeric_limits<uint64_t>::max() - digit) / 10U) {
      return false;
    }
    result = result * 10U + digit;
  }
  *out = result;
  return true;
}

std::string extract_boundary(const std::string &content_type) {
  const std::size_t first_separator = content_type.find(';');
  if (lower_copy(trim_copy(content_type.substr(0, first_separator))) !=
      "multipart/form-data") {
    return {};
  }
  std::size_t cursor = first_separator == std::string::npos
                           ? content_type.size()
                           : first_separator + 1U;
  while (cursor < content_type.size()) {
    const std::size_t next_separator = content_type.find(';', cursor);
    const std::string parameter = trim_copy(content_type.substr(
        cursor, next_separator == std::string::npos
                    ? std::string::npos
                    : next_separator - cursor));
    const std::size_t equals = parameter.find('=');
    if (equals != std::string::npos &&
        lower_copy(trim_copy(parameter.substr(0, equals))) == "boundary") {
      std::string boundary = trim_copy(parameter.substr(equals + 1U));
      if (boundary.size() >= 2U && boundary.front() == '"' &&
          boundary.back() == '"') {
        boundary = boundary.substr(1U, boundary.size() - 2U);
      } else if (boundary.find('"') != std::string::npos) {
        return {};
      }
      if (boundary.empty() || boundary.size() > 70U) return {};
      for (const char raw : boundary) {
        const unsigned char character = static_cast<unsigned char>(raw);
        const bool punctuation =
            std::strchr("'()+_,-./:=?", static_cast<int>(character)) !=
            nullptr;
        if (std::isalnum(character) == 0 && !punctuation) return {};
      }
      return boundary;
    }
    if (next_separator == std::string::npos) break;
    cursor = next_separator + 1U;
  }
  return {};
}

bool parse_pid_file_contents(const std::string &contents, uint64_t *pid,
                             uint64_t *start_epoch_ms, bool *has_start) {
  if (pid == nullptr || start_epoch_ms == nullptr || has_start == nullptr) {
    return false;
  }
  std::istringstream stream(contents);
  std::string line;
  std::unordered_map<std::string, std::string> fields;
  while (std::getline(stream, line)) {
    const std::size_t separator = line.find('=');
    if (separator != std::string::npos) {
      fields[line.substr(0, separator)] = line.substr(separator + 1U);
    }
  }
  if (fields.empty()) {
    const std::size_t first_line_end = contents.find_first_of("\r\n");
    const std::string first_line =
        trim_copy(contents.substr(0, first_line_end));
    if (!parse_u64(first_line, pid) || *pid == 0) return false;
    *has_start = false;
    *start_epoch_ms = 0;
    return true;
  }
  const auto pid_field = fields.find("pid");
  if (pid_field == fields.end() || !parse_u64(pid_field->second, pid) ||
      *pid == 0) {
    return false;
  }
  const auto start_field = fields.find("start_epoch_ms");
  *has_start = start_field != fields.end() &&
               parse_u64(start_field->second, start_epoch_ms) &&
               *start_epoch_ms > 0;
  if (!*has_start) *start_epoch_ms = 0;
  return true;
}

std::string canonical_or(const std::string &path) {
  if (path.empty()) return {};
  char resolved[PATH_MAX];
  if (::realpath(path.c_str(), resolved) != nullptr) return resolved;
  return path;
}

bool regular_file(const std::string &path) {
  struct stat information {};
  return ::stat(path.c_str(), &information) == 0 &&
         S_ISREG(information.st_mode);
}

uint64_t regular_file_size(const std::string &path) {
  struct stat information {};
  if (::stat(path.c_str(), &information) != 0 ||
      !S_ISREG(information.st_mode)) {
    return 0;
  }
  return static_cast<uint64_t>(information.st_size);
}

std::string sha256_file(const std::string &path) {
  FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return {};

  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  unsigned char buffer[1024U * 1024U];
  std::size_t bytes_read = 0;
  while ((bytes_read = std::fread(buffer, 1, sizeof(buffer), file)) > 0U) {
    CC_SHA256_Update(&context, buffer, static_cast<CC_LONG>(bytes_read));
  }
  const bool successful = std::ferror(file) == 0;
  std::fclose(file);
  if (!successful) return {};

  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const unsigned char byte : digest) {
    output << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return output.str();
}

std::string shell_quote(const std::string &value) {
  std::string quoted = "'";
  for (const char character : value) {
    if (character == '\'') {
      quoted += "'\\''";
    } else {
      quoted += character;
    }
  }
  quoted += '\'';
  return quoted;
}

std::string command_output(const std::string &command) {
  std::string output;
  FILE *pipe = ::popen(command.c_str(), "r");
  if (pipe == nullptr) return output;
  char buffer[512];
  while (std::fgets(buffer, sizeof(buffer), pipe) != nullptr) {
    output += buffer;
  }
  (void)::pclose(pipe);
  while (!output.empty() &&
         (output.back() == '\n' || output.back() == '\r')) {
    output.pop_back();
  }
  return output;
}

namespace {

std::string normalized_field_name(const char *name) {
  return name == nullptr ? std::string() : std::string(name);
}

std::string normalized_event_name(const char *event) {
  return event == nullptr ? std::string() : std::string(event);
}

std::string append_field_separator(const std::string &extra) {
  if (extra.empty() || extra.front() == ',') return extra;
  return "," + extra;
}

} // namespace

void log_event(const char *event, const std::string &extra) {
  const std::string escaped_event = json_escape(normalized_event_name(event));
  const std::string suffix = append_field_separator(extra);
  std::fprintf(stderr, "{\"event\":\"%s\",\"time_ms\":%llu%s}\n",
               escaped_event.c_str(),
               static_cast<unsigned long long>(unix_millis()), suffix.c_str());
  std::fflush(stderr);
}

void log_event(const std::string &event, const std::string &extra) {
  log_event(event.c_str(), extra);
}

std::string log_field(const char *name, const std::string &value) {
  return "," + json_quote(normalized_field_name(name)) + ":" +
         json_quote(value);
}

std::string log_field(const std::string &name, const std::string &value) {
  return log_field(name.c_str(), value);
}

std::string log_field(const char *name, const uint64_t value) {
  return "," + json_quote(normalized_field_name(name)) + ":" +
         std::to_string(value);
}

std::string log_field(const std::string &name, const uint64_t value) {
  return log_field(name.c_str(), value);
}

void set_cors(httplib::Response &response) {
  response.set_header("Access-Control-Allow-Origin", "*");
  response.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  response.set_header("Access-Control-Allow-Headers",
                      "Content-Type, Accept, Authorization, X-Request-Id");
  response.set_header("Access-Control-Max-Age", "600");
}

void set_json(httplib::Response &response, const int status,
              const std::string &body) {
  response.status = status;
  response.set_content(body, "application/json");
  set_cors(response);
}

std::string json_error(const std::string &message) {
  return "{\"error\":" + json_quote(message) + "}";
}

bool write_all(const int fd, const void *data, const std::size_t length) {
  if (fd < 0 || (data == nullptr && length != 0U)) return false;
  const char *bytes = static_cast<const char *>(data);
  std::size_t offset = 0;
  while (offset < length) {
    const ssize_t written = ::write(fd, bytes + offset, length - offset);
    if (written > 0) {
      offset += static_cast<std::size_t>(written);
      continue;
    }
    if (written < 0 && errno == EINTR) continue;
    return false;
  }
  return true;
}

ScopedFd &ScopedFd::operator=(ScopedFd &&other) noexcept {
  if (this != &other) {
    close();
    fd_ = other.release();
  }
  return *this;
}

ScopedFd::~ScopedFd() noexcept {
  close();
}

int ScopedFd::release() noexcept {
  const int released = fd_;
  fd_ = -1;
  return released;
}

bool ScopedFd::close() noexcept {
  if (fd_ < 0) return true;
  const int result = ::close(fd_);
  fd_ = -1;
  return result == 0;
}

TempUploadFile::TempUploadFile(TempUploadFile &&other) noexcept
    : fd_(other.fd_), path_(std::move(other.path_)) {
  other.fd_ = -1;
  other.path_.clear();
}

TempUploadFile &TempUploadFile::operator=(TempUploadFile &&other) noexcept {
  if (this != &other) {
    close_fd();
    unlink_path();
    fd_ = other.fd_;
    path_ = std::move(other.path_);
    other.fd_ = -1;
    other.path_.clear();
  }
  return *this;
}

TempUploadFile::~TempUploadFile() noexcept {
  close_fd();
  unlink_path();
}

bool TempUploadFile::create(const std::string &directory) {
  close_fd();
  unlink_path();
  if (directory.empty()) return false;

  std::string template_path = directory + "/gateway-upload-XXXXXX";
  std::vector<char> writable(template_path.begin(), template_path.end());
  writable.push_back('\0');
  const int created_fd = ::mkstemp(writable.data());
  if (created_fd < 0) return false;
  fd_ = created_fd;
  path_ = writable.data();
  if (::fchmod(fd_, S_IRUSR | S_IWUSR) != 0) {
    close_fd();
    unlink_path();
    return false;
  }
  return true;
}

bool TempUploadFile::close_fd() noexcept {
  if (fd_ < 0) return true;
  const int result = ::close(fd_);
  fd_ = -1;
  return result == 0;
}

bool TempUploadFile::unlink_path() noexcept {
  if (path_.empty()) return true;
  const int result = ::unlink(path_.c_str());
  const int unlink_errno = errno;
  path_.clear();
  return result == 0 || unlink_errno == ENOENT;
}

BoundedThreadPool::BoundedThreadPool(const std::size_t worker_count,
                                     const std::size_t max_queued_requests)
    : max_queued_requests_(max_queued_requests) {
  const std::size_t actual_worker_count = worker_count == 0U ? 1U : worker_count;
  workers_.reserve(actual_worker_count);
  try {
    for (std::size_t index = 0; index < actual_worker_count; ++index) {
      workers_.emplace_back([this] { worker_loop(); });
    }
  } catch (...) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      shutting_down_ = true;
    }
    condition_.notify_all();
    for (std::thread &worker : workers_) {
      if (worker.joinable()) worker.join();
    }
    throw;
  }
}

BoundedThreadPool::~BoundedThreadPool() {
  shutdown();
}

bool BoundedThreadPool::enqueue(std::function<void()> function) {
  if (!function) {
    log_event("task_queue_rejected", log_field("reason", "empty_task"));
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_ ||
        (max_queued_requests_ > 0U &&
         jobs_.size() >= max_queued_requests_)) {
      log_event("task_queue_full",
                log_field("limit", static_cast<uint64_t>(max_queued_requests_)));
      return false;
    }
    jobs_.push_back(std::move(function));
  }
  condition_.notify_one();
  return true;
}

void BoundedThreadPool::shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_) return;
    shutting_down_ = true;
  }
  condition_.notify_all();
  for (std::thread &worker : workers_) {
    if (worker.joinable()) worker.join();
  }
}

std::size_t BoundedThreadPool::queued_jobs() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return jobs_.size();
}

bool BoundedThreadPool::shutting_down() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return shutting_down_;
}

void BoundedThreadPool::worker_loop() {
  for (;;) {
    std::function<void()> function;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      condition_.wait(lock,
                      [this] { return shutting_down_ || !jobs_.empty(); });
      if (jobs_.empty()) {
        if (shutting_down_) return;
        continue;
      }
      function = std::move(jobs_.front());
      jobs_.pop_front();
    }
    try {
      function();
    } catch (const std::exception &error) {
      log_event("task_exception", log_field("what", error.what()));
    } catch (...) {
      log_event("task_exception", log_field("what", "unknown"));
    }
  }
}

} // namespace whisper_gateway
