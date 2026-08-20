#pragma once

#include "config.h"
#include "support.h"

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>

#include <sys/types.h>

namespace whisper_gateway {

enum class BackendState {
  Cold,
  Starting,
  Ready,
  Stopping,
  Backoff,
};

const char *state_name(BackendState state);

struct BackendSnapshot {
  BackendState state = BackendState::Cold;
  std::size_t active_requests = 0;
  std::uint64_t idle_remaining_seconds = 0;
  std::uint64_t backoff_remaining_seconds = 0;
  pid_t pid = -1;
};

class BackendController;

class RequestLease final {
public:
  RequestLease() = default;
  RequestLease(const RequestLease &) = delete;
  RequestLease &operator=(const RequestLease &) = delete;
  RequestLease(RequestLease &&other) noexcept;
  RequestLease &operator=(RequestLease &&other) noexcept;
  ~RequestLease();

  void finish(int status);

private:
  friend class BackendController;
  RequestLease(BackendController *controller, std::string request_id,
               TimePoint started);
  void reset(int status);

  BackendController *controller_ = nullptr;
  std::string request_id_;
  TimePoint started_{};
};

class BackendController final {
public:
  explicit BackendController(Config config);
  BackendController(const BackendController &) = delete;
  BackendController &operator=(const BackendController &) = delete;
  ~BackendController();

  const Config &config() const { return config_; }
  bool validate_startup(std::string *error);
  void start();
  void request_shutdown();
  void join();

  std::optional<RequestLease> acquire_request(const std::string &request_id,
                                              TimePoint started,
                                              TimePoint deadline);
  bool begin_backend(std::string *reason);
  bool wait_until_ready(TimePoint deadline, std::string *reason);
  BackendSnapshot snapshot() const;

private:
  friend class RequestLease;

  bool prepare_directories(std::string *error);
  void clean_old_uploads();
  void adopt_backend_if_safe();
  bool backend_is_safe_locked() const;
  bool backend_has_exited_locked();
  bool launch_backend_locked(std::string *reason);
  bool terminate_and_reap_backend_locked(pid_t pid);
  bool backend_health(TimePoint deadline) const;
  void supervisor_loop();
  bool send_backend_signal(pid_t pid, int signal, const char *event);
  void set_backoff_locked(const std::string &reason);
  void finish_request(const std::string &request_id, TimePoint started,
                      int status);

  Config config_;
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  BackendState state_ = BackendState::Cold;
  pid_t backend_pid_ = -1;
  std::uint64_t backend_start_epoch_ms_ = 0;
  bool backend_adopted_ = false;
  std::size_t active_requests_ = 0;
  TimePoint last_request_finished_ = Clock::now();
  TimePoint state_changed_ = Clock::now();
  TimePoint backoff_until_ = TimePoint::min();
  bool shutting_down_ = false;
  std::unordered_map<std::string, TimePoint> request_deadlines_;
  std::thread supervisor_thread_;
};

} // namespace whisper_gateway
