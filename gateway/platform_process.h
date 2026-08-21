#pragma once

// macOS process and child-process primitives used by the on-demand backend.
//
// This header intentionally contains no gateway state-machine or HTTP types.
// Callers own the synchronization around these operations.  In particular,
// process_matches() and signal_if_matches() are observations followed by a
// signal; callers must still hold whatever state lock protects their PID
// ownership while using them.

#include <sys/types.h>

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace whisper_gateway {

constexpr uint64_t kProcessStartToleranceMs = 2000;

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

// The expected identity is deliberately separate from ProcessRecord.  A
// record is persisted state supplied by the process that spawned the child;
// this type is the current configuration against which it is checked.
struct ProcessIdentity {
  std::string binary;
  std::string model;
  uint64_t model_size = 0;
  std::string model_sha256;
  int port = 0;
  std::string host;
  std::vector<std::string> argv;
  std::optional<uid_t> uid;
  uint64_t start_tolerance_ms = kProcessStartToleranceMs;
};

struct SpawnSpec {
  std::string executable;
  std::vector<std::string> argv;
  std::string log_path;
};

struct SpawnResult {
  pid_t pid = -1;
  // This is the wall-clock timestamp taken immediately after posix_spawn.
  // It is compared with proc_pidinfo()'s process start time using the
  // tolerance in ProcessIdentity.
  uint64_t start_epoch_ms = 0;
};

enum class ReapStatus {
  Running,
  Reaped,
  Exited,
  NotChild,
  Error,
};

struct ReapResult {
  ReapStatus status = ReapStatus::Error;
  int wait_status = 0;
  int error = 0;
};

bool write_process_record(const std::string &path, const ProcessRecord &record,
                          std::string *error = nullptr);
bool read_process_record(const std::string &path, ProcessRecord *record,
                         std::string *error = nullptr);

bool process_alive(pid_t pid);
bool process_is_zombie(pid_t pid);
bool process_uid_matches(pid_t pid);
bool process_uid_matches(pid_t pid, uid_t expected_uid);
std::string process_binary(pid_t pid);
uint64_t process_start_epoch_ms(pid_t pid);
bool read_process_argv(pid_t pid, const std::string &expected_binary,
                       std::vector<std::string> *argv,
                       std::string *error = nullptr);

bool process_matches(const ProcessRecord &record, const ProcessIdentity &expected,
                     std::string *error = nullptr);

// Re-checks the complete process identity immediately before sending the
// signal.  Signal 0 is deliberately rejected: this API is for lifecycle
// actions, not for an unqualified liveness probe.
bool signal_if_matches(const ProcessRecord &record, const ProcessIdentity &expected,
                       int signal_number, std::string *error = nullptr);

bool tcp_port_listening(
    const std::string &host, int port,
    std::chrono::milliseconds timeout = std::chrono::milliseconds(100),
    std::string *error = nullptr);

bool spawn_process(const SpawnSpec &spec, SpawnResult *result,
                   std::string *error = nullptr);

// If owned_child is true, perform WNOHANG waitpid and a second wait after a
// zombie observation so a child zombie is reaped.  If false, only observe the
// process: adopted PIDs are owned by their original parent and must never be
// passed to waitpid by the gateway.
ReapResult reap_child(pid_t pid, bool owned_child);

}  // namespace whisper_gateway

// Keep the short aliases available to callers that already group gateway
// modules below whisper::platform or use the file-oriented spelling.
namespace whisper {
namespace platform = whisper_gateway;
namespace platform_process = whisper_gateway;
}  // namespace whisper
