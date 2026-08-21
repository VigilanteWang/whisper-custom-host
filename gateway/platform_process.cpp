#include "platform_process.h"

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>

#include <cerrno>
#include <cctype>
#include <chrono>
#include <cstring>
#include <fstream>
#include <limits>
#include <sstream>
#include <unordered_map>

extern char **environ;

namespace whisper_gateway {
namespace {

constexpr size_t kMaximumRecordBytes = 64U * 1024U;
constexpr size_t kMaximumProcessArgsBytes = 1024U * 1024U;

void set_error(std::string *error, const std::string &message) {
  if (error != nullptr) *error = message;
}

std::string lower_copy(std::string value) {
  for (char &raw : value) {
    raw = static_cast<char>(std::tolower(static_cast<unsigned char>(raw)));
  }
  return value;
}

bool parse_u64(const std::string &value, uint64_t *out) {
  if (out == nullptr || value.empty()) return false;
  uint64_t result = 0;
  for (const char raw : value) {
    const unsigned char digit = static_cast<unsigned char>(raw);
    if (digit < static_cast<unsigned char>('0') || digit > static_cast<unsigned char>('9')) return false;
    const uint64_t number = static_cast<uint64_t>(digit - static_cast<unsigned char>('0'));
    if (result > (std::numeric_limits<uint64_t>::max() - number) / 10U) return false;
    result = result * 10U + number;
  }
  *out = result;
  return true;
}

bool contains_line_break(const std::string &value) {
  return value.find('\n') != std::string::npos || value.find('\r') != std::string::npos;
}

bool valid_record_for_write(const ProcessRecord &record, std::string *error) {
  if (record.pid <= 0 || record.start_epoch_ms == 0) {
    set_error(error, "invalid process pid or start time");
    return false;
  }
  if (record.binary.empty() || record.model.empty() || record.host.empty() ||
      record.model_sha256.empty() || record.model_size == 0 ||
      record.port < 1 || record.port > 65535) {
    set_error(error, "incomplete process identity record");
    return false;
  }
  if (contains_line_break(record.binary) || contains_line_break(record.model) ||
      contains_line_break(record.host) || contains_line_break(record.model_sha256)) {
    set_error(error, "process identity contains a line break");
    return false;
  }
  return true;
}

class ScopedFd final {
public:
  explicit ScopedFd(int fd = -1) : fd_(fd) {}
  ScopedFd(const ScopedFd &) = delete;
  ScopedFd &operator=(const ScopedFd &) = delete;
  ~ScopedFd() { close(); }

  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }
  bool close() {
    if (fd_ < 0) return true;
    const int result = ::close(fd_);
    fd_ = -1;
    return result == 0;
  }

private:
  int fd_ = -1;
};

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

bool read_all(int fd, std::string *contents, std::string *error) {
  if (contents == nullptr) {
    set_error(error, "null output for process record");
    return false;
  }
  contents->clear();
  char buffer[4096];
  for (;;) {
    const ssize_t read_count = ::read(fd, buffer, sizeof(buffer));
    if (read_count > 0) {
      if (contents->size() > kMaximumRecordBytes - static_cast<size_t>(read_count)) {
        set_error(error, "process identity record is too large");
        return false;
      }
      contents->append(buffer, static_cast<size_t>(read_count));
      continue;
    }
    if (read_count == 0) return true;
    if (errno == EINTR) continue;
    set_error(error, std::string("read process identity record failed: ") + std::strerror(errno));
    return false;
  }
}

bool file_is_owned_private_regular(int fd, std::string *error) {
  struct stat info{};
  if (::fstat(fd, &info) != 0) {
    set_error(error, std::string("stat process identity record failed: ") + std::strerror(errno));
    return false;
  }
  if (!S_ISREG(info.st_mode)) {
    set_error(error, "process identity record is not a regular file");
    return false;
  }
  if (info.st_uid != ::geteuid()) {
    set_error(error, "process identity record is owned by another user");
    return false;
  }
  if ((info.st_mode & 0077) != 0) {
    set_error(error, "process identity record is accessible by another user");
    return false;
  }
  return true;
}

bool field_value(const std::unordered_map<std::string, std::string> &fields,
                 const char *name, std::string *value) {
  const auto found = fields.find(name);
  if (found == fields.end() || found->second.empty()) return false;
  *value = found->second;
  return true;
}

bool parse_record_text(const std::string &contents, ProcessRecord *record,
                       std::string *error) {
  if (record == nullptr) {
    set_error(error, "null process identity record output");
    return false;
  }
  std::unordered_map<std::string, std::string> fields;
  std::istringstream stream(contents);
  std::string line;
  while (std::getline(stream, line)) {
    const size_t separator = line.find('=');
    if (separator == std::string::npos || separator == 0) {
      set_error(error, "malformed process identity record line");
      return false;
    }
    const std::string key = line.substr(0, separator);
    if (fields.find(key) != fields.end()) {
      set_error(error, "duplicate process identity record field");
      return false;
    }
    fields.emplace(key, line.substr(separator + 1));
  }

  std::string pid_text;
  std::string start_text;
  std::string model_size_text;
  std::string port_text;
  if (!field_value(fields, "pid", &pid_text) ||
      !field_value(fields, "start_epoch_ms", &start_text) ||
      !field_value(fields, "model_size", &model_size_text) ||
      !field_value(fields, "port", &port_text) ||
      !field_value(fields, "binary", &record->binary) ||
      !field_value(fields, "model", &record->model) ||
      !field_value(fields, "model_sha256", &record->model_sha256) ||
      !field_value(fields, "host", &record->host)) {
    set_error(error, "incomplete process identity record");
    return false;
  }

  uint64_t pid = 0;
  uint64_t start = 0;
  uint64_t model_size = 0;
  uint64_t port = 0;
  if (!parse_u64(pid_text, &pid) || pid == 0 ||
      pid > static_cast<uint64_t>(std::numeric_limits<pid_t>::max()) ||
      !parse_u64(start_text, &start) || start == 0 ||
      !parse_u64(model_size_text, &model_size) || model_size == 0 ||
      !parse_u64(port_text, &port) || port < 1 || port > 65535) {
    set_error(error, "invalid numeric process identity field");
    return false;
  }
  record->pid = static_cast<pid_t>(pid);
  record->start_epoch_ms = start;
  record->model_size = model_size;
  record->port = static_cast<int>(port);
  record->model_sha256 = lower_copy(record->model_sha256);
  return valid_record_for_write(*record, error);
}

std::string canonical_or(const std::string &path) {
  if (path.empty()) return {};
  char resolved[PATH_MAX];
  if (::realpath(path.c_str(), resolved) != nullptr) return resolved;
  return path;
}

uint64_t unix_millis() {
  const auto now = std::chrono::system_clock::now().time_since_epoch();
  const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
  if (millis <= 0) return 0;
  return static_cast<uint64_t>(millis);
}

bool actual_argv_matches(const std::vector<std::string> &actual,
                         const std::vector<std::string> &expected) {
  if (actual.size() != expected.size() || actual.empty()) return false;
  if (canonical_or(actual.front()) != canonical_or(expected.front())) return false;
  for (size_t index = 1; index < expected.size(); ++index) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

}  // namespace

bool write_process_record(const std::string &path, const ProcessRecord &record,
                          std::string *error) {
  if (path.empty()) {
    set_error(error, "empty process identity record path");
    return false;
  }
  if (!valid_record_for_write(record, error)) return false;

  const std::string temporary_path = path + ".tmp." + std::to_string(static_cast<long long>(::getpid()));
  ScopedFd fd(::open(temporary_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!fd.valid()) {
    set_error(error, std::string("open process identity record failed: ") + std::strerror(errno));
    return false;
  }
  const auto remove_temporary = [&temporary_path] { (void)::unlink(temporary_path.c_str()); };
  (void)::fchmod(fd.get(), 0600);
  const std::string text =
      "pid=" + std::to_string(static_cast<long long>(record.pid)) + "\n" +
      "start_epoch_ms=" + std::to_string(record.start_epoch_ms) + "\n" +
      "binary=" + record.binary + "\n" +
      "model=" + record.model + "\n" +
      "model_size=" + std::to_string(record.model_size) + "\n" +
      "model_sha256=" + lower_copy(record.model_sha256) + "\n" +
      "host=" + record.host + "\n" +
      "port=" + std::to_string(record.port) + "\n";
  if (!write_all(fd.get(), text.data(), text.size()) || ::fsync(fd.get()) != 0 || !fd.close() ||
      ::rename(temporary_path.c_str(), path.c_str()) != 0) {
    const int saved_errno = errno;
    remove_temporary();
    set_error(error, std::string("write process identity record failed: ") + std::strerror(saved_errno));
    return false;
  }
  (void)::chmod(path.c_str(), 0600);
  return true;
}

bool read_process_record(const std::string &path, ProcessRecord *record,
                         std::string *error) {
  if (record == nullptr || path.empty()) {
    set_error(error, "invalid process identity record input");
    return false;
  }
  *record = ProcessRecord{};
  ScopedFd fd(::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (!fd.valid()) {
    set_error(error, std::string("open process identity record failed: ") + std::strerror(errno));
    return false;
  }
  if (!file_is_owned_private_regular(fd.get(), error)) return false;
  std::string contents;
  if (!read_all(fd.get(), &contents, error)) return false;
  return parse_record_text(contents, record, error);
}

bool process_alive(pid_t pid) {
  if (pid <= 0) return false;
  if (::kill(pid, 0) == 0) return true;
  return errno == EPERM;
}

bool process_is_zombie(pid_t pid) {
  if (pid <= 0) return false;
  struct proc_bsdinfo info{};
  const int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  return bytes == static_cast<int>(sizeof(info)) && info.pbi_status == SZOMB;
}

bool process_uid_matches(pid_t pid, uid_t expected_uid) {
  if (pid <= 0) return false;
  struct proc_bsdinfo info{};
  const int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  return bytes == static_cast<int>(sizeof(info)) && info.pbi_uid == expected_uid;
}

bool process_uid_matches(pid_t pid) {
  return process_uid_matches(pid, ::geteuid());
}

std::string process_binary(pid_t pid) {
  if (pid <= 0) return {};
  char path[PROC_PIDPATHINFO_MAXSIZE];
  const int bytes = proc_pidpath(pid, path, sizeof(path));
  if (bytes <= 0) return {};
  return std::string(path, static_cast<size_t>(bytes));
}

uint64_t process_start_epoch_ms(pid_t pid) {
  if (pid <= 0) return 0;
  struct proc_bsdinfo info{};
  const int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  if (bytes != static_cast<int>(sizeof(info))) return 0;
  return static_cast<uint64_t>(info.pbi_start_tvsec) * 1000U +
         static_cast<uint64_t>(info.pbi_start_tvusec) / 1000U;
}

bool read_process_argv(pid_t pid, const std::string &expected_binary,
                       std::vector<std::string> *argv, std::string *error) {
  if (pid <= 0 || expected_binary.empty() || argv == nullptr) {
    set_error(error, "invalid process argv query");
    return false;
  }
  argv->clear();
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  if (::sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0 || size < sizeof(int) ||
      size > kMaximumProcessArgsBytes) {
    set_error(error, "cannot query process argv size");
    return false;
  }
  std::vector<char> buffer(size);
  if (::sysctl(mib, 3, buffer.data(), &size, nullptr, 0) != 0 ||
      size < sizeof(int) || size > buffer.size()) {
    set_error(error, "cannot query process argv");
    return false;
  }
  int argc = 0;
  std::memcpy(&argc, buffer.data(), sizeof(argc));
  if (argc <= 0 || argc > 1024) {
    set_error(error, "invalid process argc");
    return false;
  }
  const char *cursor = buffer.data() + sizeof(argc);
  const char *end = buffer.data() + size;
  std::vector<std::string> strings;
  while (cursor < end) {
    const size_t remaining = static_cast<size_t>(end - cursor);
    const size_t length = ::strnlen(cursor, remaining);
    if (length >= remaining) break;
    strings.emplace_back(cursor, length);
    cursor += length + 1;
  }
  const std::string canonical_binary = canonical_or(expected_binary);
  for (size_t start = 0; start + static_cast<size_t>(argc) <= strings.size(); ++start) {
    if (canonical_or(strings[start]) != canonical_binary) continue;
    // The gateway backend is required to expose --host immediately after the
    // executable.  This prevents matching a coincidental path in env strings.
    if (static_cast<size_t>(argc) < 2 || start + 1 >= strings.size() || strings[start + 1] != "--host") continue;
    argv->assign(strings.begin() + static_cast<std::ptrdiff_t>(start),
                 strings.begin() + static_cast<std::ptrdiff_t>(start + static_cast<size_t>(argc)));
    return true;
  }
  set_error(error, "process argv does not identify the expected executable");
  return false;
}

bool process_matches(const ProcessRecord &record, const ProcessIdentity &expected,
                     std::string *error) {
  if (record.pid <= 0 || expected.binary.empty() || expected.model.empty() ||
      expected.model_sha256.empty() || expected.model_size == 0 ||
      expected.host.empty() || expected.port < 1 || expected.port > 65535) {
    set_error(error, "incomplete expected process identity");
    return false;
  }
  if (!process_alive(record.pid)) {
    set_error(error, "process is not alive");
    return false;
  }
  if (process_is_zombie(record.pid)) {
    set_error(error, "process is a zombie");
    return false;
  }
  const uid_t uid = expected.uid.has_value() ? *expected.uid : ::geteuid();
  if (!process_uid_matches(record.pid, uid)) {
    set_error(error, "process uid does not match");
    return false;
  }
  if (canonical_or(process_binary(record.pid)) != canonical_or(expected.binary)) {
    set_error(error, "process binary does not match");
    return false;
  }
  if (record.binary != expected.binary || record.model != expected.model ||
      record.model_size != expected.model_size ||
      lower_copy(record.model_sha256) != lower_copy(expected.model_sha256) ||
      record.host != expected.host || record.port != expected.port) {
    set_error(error, "persisted process identity does not match");
    return false;
  }
  const uint64_t actual_start = process_start_epoch_ms(record.pid);
  if (actual_start == 0 || record.start_epoch_ms == 0) {
    set_error(error, "cannot query process start time");
    return false;
  }
  const uint64_t difference = actual_start >= record.start_epoch_ms
                                  ? actual_start - record.start_epoch_ms
                                  : record.start_epoch_ms - actual_start;
  if (difference > expected.start_tolerance_ms) {
    set_error(error, "process start time does not match");
    return false;
  }
  if (!expected.argv.empty()) {
    std::vector<std::string> actual_argv;
    if (!read_process_argv(record.pid, expected.binary, &actual_argv, error) ||
        !actual_argv_matches(actual_argv, expected.argv)) {
      set_error(error, "process argv does not match");
      return false;
    }
  }
  return true;
}

bool signal_if_matches(const ProcessRecord &record, const ProcessIdentity &expected,
                       int signal_number, std::string *error) {
  if (signal_number <= 0) {
    set_error(error, "invalid lifecycle signal");
    return false;
  }
  std::string identity_error;
  if (!process_matches(record, expected, &identity_error)) {
    set_error(error, "identity check failed before signal: " + identity_error);
    return false;
  }
  if (::kill(record.pid, signal_number) != 0) {
    set_error(error, std::string("signal failed: ") + std::strerror(errno));
    return false;
  }
  return true;
}

bool tcp_port_listening(const std::string &host, int port,
                        std::chrono::milliseconds timeout, std::string *error) {
  if (host.empty() || port < 1 || port > 65535 || timeout.count() < 0) {
    set_error(error, "invalid TCP port probe parameters");
    return false;
  }
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    set_error(error, std::string("socket failed: ") + std::strerror(errno));
    return false;
  }
  ScopedFd socket_fd(fd);
  struct sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(port));
  if (::inet_pton(AF_INET, host.c_str(), &address.sin_addr) != 1) {
    set_error(error, "TCP port probe requires an IPv4 address");
    return false;
  }
  const int flags = ::fcntl(fd, F_GETFL, 0);
  if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
    set_error(error, std::string("configure TCP port probe failed: ") + std::strerror(errno));
    return false;
  }
  const int connect_result = ::connect(fd, reinterpret_cast<struct sockaddr *>(&address), sizeof(address));
  if (connect_result != 0 && errno != EINPROGRESS) return false;

  const auto timeout_millis = timeout.count();
  struct timeval select_timeout{};
  select_timeout.tv_sec = static_cast<time_t>(timeout_millis / 1000);
  select_timeout.tv_usec = static_cast<suseconds_t>((timeout_millis % 1000) * 1000);
  fd_set write_set;
  FD_ZERO(&write_set);
  FD_SET(fd, &write_set);
  int selected = 0;
  do {
    selected = ::select(fd + 1, nullptr, &write_set, nullptr, &select_timeout);
  } while (selected < 0 && errno == EINTR);
  if (selected <= 0) return false;
  int socket_error = 0;
  socklen_t socket_error_length = sizeof(socket_error);
  if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &socket_error_length) != 0) {
    set_error(error, std::string("query TCP port probe failed: ") + std::strerror(errno));
    return false;
  }
  return socket_error == 0;
}

bool spawn_process(const SpawnSpec &spec, SpawnResult *result, std::string *error) {
  if (result == nullptr) {
    set_error(error, "null process spawn output");
    return false;
  }
  *result = SpawnResult{};
  if (spec.executable.empty() || spec.argv.empty() || spec.log_path.empty()) {
    set_error(error, "invalid process spawn specification");
    return false;
  }
  if (spec.argv.front() != spec.executable) {
    set_error(error, "spawn argv[0] must equal executable");
    return false;
  }

  ScopedFd log_fd(::open(spec.log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600));
  if (!log_fd.valid()) {
    set_error(error, std::string("open backend log failed: ") + std::strerror(errno));
    return false;
  }
  (void)::fchmod(log_fd.get(), 0600);

  std::vector<char *> argv;
  argv.reserve(spec.argv.size() + 1);
  for (const std::string &argument : spec.argv) {
    argv.push_back(const_cast<char *>(argument.c_str()));
  }
  argv.push_back(nullptr);

  posix_spawn_file_actions_t actions;
  int operation = ::posix_spawn_file_actions_init(&actions);
  if (operation != 0) {
    set_error(error, std::string("initialize spawn file actions failed: ") + std::strerror(operation));
    return false;
  }
  bool actions_initialized = true;
  const auto destroy_actions = [&actions, &actions_initialized] {
    if (actions_initialized) {
      (void)::posix_spawn_file_actions_destroy(&actions);
      actions_initialized = false;
    }
  };
  operation = ::posix_spawn_file_actions_adddup2(&actions, log_fd.get(), STDOUT_FILENO);
  if (operation == 0) operation = ::posix_spawn_file_actions_adddup2(&actions, log_fd.get(), STDERR_FILENO);
  if (operation == 0) operation = ::posix_spawn_file_actions_addclose(&actions, log_fd.get());
  if (operation != 0) {
    destroy_actions();
    set_error(error, std::string("configure spawn file actions failed: ") + std::strerror(operation));
    return false;
  }

  posix_spawnattr_t attributes;
  operation = ::posix_spawnattr_init(&attributes);
  if (operation != 0) {
    destroy_actions();
    set_error(error, std::string("initialize spawn attributes failed: ") + std::strerror(operation));
    return false;
  }
  bool attributes_initialized = true;
  const auto destroy_attributes = [&attributes, &attributes_initialized] {
    if (attributes_initialized) {
      (void)::posix_spawnattr_destroy(&attributes);
      attributes_initialized = false;
    }
  };
  sigset_t child_signal_mask;
  if (sigemptyset(&child_signal_mask) != 0) operation = errno;
  else operation = ::posix_spawnattr_setsigmask(&attributes, &child_signal_mask);
  if (operation == 0) operation = ::posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK);
  if (operation != 0) {
    destroy_attributes();
    destroy_actions();
    set_error(error, std::string("configure child signal mask failed: ") + std::strerror(operation));
    return false;
  }

  pid_t child = -1;
  const int spawn_result = ::posix_spawn(&child, spec.executable.c_str(), &actions, &attributes,
                                         argv.data(), environ);
  destroy_attributes();
  destroy_actions();
  if (spawn_result != 0) {
    set_error(error, std::string("posix_spawn failed: ") + std::strerror(spawn_result));
    return false;
  }
  const uint64_t start_epoch_ms = unix_millis();
  if (start_epoch_ms == 0) {
    (void)::kill(child, SIGTERM);
    int ignored_status = 0;
    (void)::waitpid(child, &ignored_status, 0);
    set_error(error, "cannot obtain child start timestamp");
    return false;
  }
  result->pid = child;
  result->start_epoch_ms = start_epoch_ms;
  return true;
}

ReapResult reap_child(pid_t pid, bool owned_child) {
  ReapResult result;
  if (pid <= 0) {
    result.status = ReapStatus::Error;
    result.error = EINVAL;
    return result;
  }
  if (!owned_child) {
    result.status = process_is_zombie(pid) || !process_alive(pid)
                        ? ReapStatus::Exited
                        : ReapStatus::Running;
    return result;
  }

  int status = 0;
  const pid_t waited = ::waitpid(pid, &status, WNOHANG);
  if (waited == pid) {
    result.status = ReapStatus::Reaped;
    result.wait_status = status;
    return result;
  }
  if (waited < 0 && errno != EINTR && errno != ECHILD) {
    result.status = ReapStatus::Error;
    result.error = errno;
    return result;
  }
  // A child can turn into a zombie after WNOHANG reports no status.  The
  // second wait is intentional: it closes the race without leaving a zombie
  // behind when the controller clears the PID.
  if (process_is_zombie(pid)) {
    const pid_t reaped = ::waitpid(pid, &status, WNOHANG);
    if (reaped == pid) {
      result.status = ReapStatus::Reaped;
      result.wait_status = status;
      return result;
    }
    if (reaped < 0 && errno == ECHILD) {
      result.status = ReapStatus::NotChild;
      result.error = ECHILD;
      return result;
    }
    if (reaped < 0 && errno != EINTR) {
      result.status = ReapStatus::Error;
      result.error = errno;
      return result;
    }
    result.status = ReapStatus::Running;
    return result;
  }
  if (waited < 0 && errno == ECHILD) {
    result.status = ReapStatus::NotChild;
    result.error = ECHILD;
    return result;
  }
  result.status = process_alive(pid) ? ReapStatus::Running : ReapStatus::Exited;
  return result;
}

}  // namespace whisper_gateway
