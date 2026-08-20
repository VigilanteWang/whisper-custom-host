#include "../gateway/platform_process.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

bool check(bool condition, const char *message) {
  if (condition) return true;
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

}  // namespace

int main() {
  using namespace whisper_gateway;

  char directory[] = "/tmp/whisper-platform-process-unit.XXXXXX";
  if (!check(::mkdtemp(directory) != nullptr, "mkdtemp")) return 1;
  const std::string root = directory;
  const std::string record_path = root + "/backend.state";
  const std::string log_path = root + "/backend.log";

  ProcessRecord original;
  original.pid = ::getpid();
  original.start_epoch_ms = process_start_epoch_ms(original.pid);
  original.binary = process_binary(original.pid);
  original.model = "/tmp/ggml-test.bin";
  original.model_size = 1234;
  original.model_sha256 = "ABCDEF";
  original.host = "127.0.0.1";
  original.port = 18080;
  if (!check(process_alive(original.pid), "current process is alive") ||
      !check(!process_is_zombie(original.pid), "current process is not a zombie") ||
      !check(process_uid_matches(original.pid, ::geteuid()), "current process uid matches") ||
      !check(!original.binary.empty(), "current process binary is available") ||
      !check(original.start_epoch_ms != 0, "current process start time is available")) {
    (void)::rmdir(directory);
    return 1;
  }

  std::string error;
  if (!check(write_process_record(record_path, original, &error), "write process record")) {
    std::cerr << error << '\n';
    (void)::rmdir(directory);
    return 1;
  }
  struct stat record_stat{};
  if (!check(::stat(record_path.c_str(), &record_stat) == 0, "stat process record") ||
      !check((record_stat.st_mode & static_cast<mode_t>(0777)) == static_cast<mode_t>(0600),
             "process record is private")) {
    (void)::unlink(record_path.c_str());
    (void)::rmdir(directory);
    return 1;
  }
  ProcessRecord round_trip;
  if (!check(read_process_record(record_path, &round_trip, &error), "read process record")) {
    std::cerr << error << '\n';
    (void)::unlink(record_path.c_str());
    (void)::rmdir(directory);
    return 1;
  }
  if (!check(round_trip.pid == original.pid, "record pid round trip") ||
      !check(round_trip.start_epoch_ms == original.start_epoch_ms, "record start time round trip") ||
      !check(round_trip.binary == original.binary, "record binary round trip") ||
      !check(round_trip.model_sha256 == "abcdef", "record hash normalized") ||
      !check(round_trip.port == original.port, "record port round trip")) {
    (void)::unlink(record_path.c_str());
    (void)::rmdir(directory);
    return 1;
  }

  const int listener = ::socket(AF_INET, SOCK_STREAM, 0);
  if (!check(listener >= 0, "create TCP listener")) return 1;
  struct sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(0);
  bool ok = ::bind(listener, reinterpret_cast<struct sockaddr *>(&address), sizeof(address)) == 0;
  ok = ok && ::listen(listener, 1) == 0;
  socklen_t address_length = sizeof(address);
  ok = ok && ::getsockname(listener, reinterpret_cast<struct sockaddr *>(&address), &address_length) == 0;
  const int listener_port = static_cast<int>(ntohs(address.sin_port));
  if (!check(ok, "bind TCP listener") ||
      !check(tcp_port_listening("127.0.0.1", listener_port), "detect listening TCP port")) {
    (void)::close(listener);
    (void)::unlink(record_path.c_str());
    (void)::rmdir(directory);
    return 1;
  }
  (void)::close(listener);

  SpawnSpec spec;
  spec.executable = "/bin/sh";
  spec.argv = {"/bin/sh", "-c", "exit 0"};
  spec.log_path = log_path;
  SpawnResult child;
  if (!check(spawn_process(spec, &child, &error), "spawn child")) {
    std::cerr << error << '\n';
    (void)::unlink(record_path.c_str());
    (void)::rmdir(directory);
    return 1;
  }
  bool reaped = false;
  for (int attempt = 0; attempt < 200 && !reaped; ++attempt) {
    const ReapResult reap = reap_child(child.pid, true);
    if (reap.status == ReapStatus::Reaped || reap.status == ReapStatus::Exited ||
        reap.status == ReapStatus::NotChild) {
      reaped = true;
    } else if (reap.status == ReapStatus::Error) {
      std::cerr << "FAIL: reap child errno=" << reap.error << '\n';
      break;
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
  if (!check(reaped, "reap spawned child") ||
      !check(reap_child(::getpid(), false).status == ReapStatus::Running,
             "adopted observation does not waitpid")) {
    (void)::unlink(record_path.c_str());
    (void)::unlink(log_path.c_str());
    (void)::rmdir(directory);
    return 1;
  }

  (void)::unlink(record_path.c_str());
  (void)::unlink(log_path.c_str());
  if (!check(::rmdir(directory) == 0, "remove temporary directory")) return 1;
  std::cout << "platform-process-unit: PASS\n";
  return 0;
}

