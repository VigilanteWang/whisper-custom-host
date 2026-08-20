#pragma once

#include "httplib.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

namespace whisper_gateway {

// Monotonic time is used for request and lifecycle deadlines.  Wall-clock
// timestamps are only used for human- and machine-readable log records.
using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

uint64_t unix_millis();

bool deadline_expired(TimePoint deadline);

// Configure all cpp-httplib client timeouts from one absolute deadline.  A
// non-positive maximum means "no additional maximum".  TimePoint::max()
// therefore requires a positive maximum to be useful.
bool configure_client_deadline(
    httplib::Client &client,
    TimePoint deadline,
    std::chrono::milliseconds maximum = std::chrono::milliseconds::zero());

std::string json_escape(const std::string &value);
std::string json_quote(const std::string &value);

// Small filesystem/process helpers shared by configuration and lifecycle
// modules.  They intentionally report failure through an empty string/zero;
// callers use the result in their own user-facing diagnostic context.
std::string lower_copy(std::string value);
std::string trim_copy(std::string value);
bool parse_u64(std::string_view value, uint64_t *out);
std::string extract_boundary(const std::string &content_type);
bool parse_pid_file_contents(const std::string &contents, uint64_t *pid,
                             uint64_t *start_epoch_ms, bool *has_start);
std::string canonical_or(const std::string &path);
bool regular_file(const std::string &path);
uint64_t regular_file_size(const std::string &path);
std::string sha256_file(const std::string &path);
std::string shell_quote(const std::string &value);
std::string command_output(const std::string &command);

// `extra` is a pre-built sequence of comma-prefixed JSON object fields, for
// example log_field("pid", 42).  Keeping this small contract makes it cheap
// for hot paths to append optional fields without allocating a map.
void log_event(const char *event, const std::string &extra = {});
void log_event(const std::string &event, const std::string &extra = {});
std::string log_field(const char *name, const std::string &value);
std::string log_field(const std::string &name, const std::string &value);
std::string log_field(const char *name, uint64_t value);
std::string log_field(const std::string &name, uint64_t value);

void set_cors(httplib::Response &response);
void set_json(httplib::Response &response, int status, const std::string &body);
std::string json_error(const std::string &message);

template <typename F>
class ScopeExit final {
public:
  explicit ScopeExit(F function) noexcept(
      std::is_nothrow_move_constructible<F>::value)
      : function_(std::move(function)) {}

  ScopeExit(const ScopeExit &) = delete;
  ScopeExit &operator=(const ScopeExit &) = delete;

  ScopeExit(ScopeExit &&other) noexcept(
      std::is_nothrow_move_constructible<F>::value)
      : function_(std::move(other.function_)), active_(other.active_) {
    other.active_ = false;
  }

  ScopeExit &operator=(ScopeExit &&other) noexcept(
      std::is_nothrow_move_assignable<F>::value &&
      std::is_nothrow_move_constructible<F>::value) {
    if (this != &other) {
      if (active_) function_();
      function_ = std::move(other.function_);
      active_ = other.active_;
      other.active_ = false;
    }
    return *this;
  }

  ~ScopeExit() noexcept {
    if (active_) function_();
  }

  void dismiss() noexcept { active_ = false; }
  bool active() const noexcept { return active_; }

private:
  F function_;
  bool active_ = true;
};

template <typename F>
ScopeExit<F> make_scope_exit(F function) noexcept(
    std::is_nothrow_move_constructible<F>::value) {
  return ScopeExit<F>(std::move(function));
}

bool write_all(int fd, const void *data, std::size_t length);

inline bool write_all(int fd, const std::string &value) {
  return write_all(fd, value.data(), value.size());
}

class ScopedFd final {
public:
  explicit ScopedFd(int fd = -1) noexcept : fd_(fd) {}
  ScopedFd(const ScopedFd &) = delete;
  ScopedFd &operator=(const ScopedFd &) = delete;
  ScopedFd(ScopedFd &&other) noexcept : fd_(other.release()) {}
  ScopedFd &operator=(ScopedFd &&other) noexcept;
  ~ScopedFd() noexcept;

  int get() const noexcept { return fd_; }
  bool valid() const noexcept { return fd_ >= 0; }
  int release() noexcept;
  bool close() noexcept;

private:
  int fd_ = -1;
};

// A mode-0600 mkstemp file whose descriptor and pathname are both cleaned up
// on every exit path.  The pathname remains available until unlink_path() is
// called so callers can pass it to a backend after closing the descriptor.
class TempUploadFile final {
public:
  TempUploadFile() = default;
  TempUploadFile(const TempUploadFile &) = delete;
  TempUploadFile &operator=(const TempUploadFile &) = delete;
  TempUploadFile(TempUploadFile &&other) noexcept;
  TempUploadFile &operator=(TempUploadFile &&other) noexcept;
  ~TempUploadFile() noexcept;

  bool create(const std::string &directory);
  int fd() const noexcept { return fd_; }
  bool valid() const noexcept { return fd_ >= 0 && !path_.empty(); }
  const std::string &path() const noexcept { return path_; }
  bool close_fd() noexcept;
  bool unlink_path() noexcept;

private:
  int fd_ = -1;
  std::string path_;
};

// cpp-httplib owns and deletes its TaskQueue after Server::listen exits.  This
// implementation bounds waiting sockets, while retaining the library's
// drain-on-shutdown behavior for already accepted jobs.
class BoundedThreadPool final : public httplib::TaskQueue {
public:
  BoundedThreadPool(std::size_t worker_count, std::size_t max_queued_requests);
  BoundedThreadPool(const BoundedThreadPool &) = delete;
  BoundedThreadPool &operator=(const BoundedThreadPool &) = delete;
  ~BoundedThreadPool() override;

  bool enqueue(std::function<void()> function) override;
  void shutdown() override;

  std::size_t queued_jobs() const;
  bool shutting_down() const;

private:
  void worker_loop();

  const std::size_t max_queued_requests_;
  bool shutting_down_ = false;
  std::deque<std::function<void()>> jobs_;
  std::vector<std::thread> workers_;
  mutable std::mutex mutex_;
  std::condition_variable condition_;
};

} // namespace whisper_gateway
