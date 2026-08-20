#include "support.h"

#include <cassert>
#include <chrono>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>

#include <sys/stat.h>
#include <unistd.h>

namespace {

void test_json_and_http_helpers() {
  std::string value;
  value.push_back('"');
  value.push_back('\\');
  value.push_back('\n');
  value.push_back('\r');
  value.push_back('\t');
  value.push_back('\0');
  value.push_back('\x01');
  assert(whisper_gateway::json_escape(value) ==
         "\\\"\\\\\\n\\r\\t\\u0000\\u0001");
  assert(whisper_gateway::json_quote("ok") == "\"ok\"");
  assert(whisper_gateway::json_error("bad\n") ==
         "{\"error\":\"bad\\n\"}");
  assert(whisper_gateway::log_field("name", std::string("a\"b")) ==
         ",\"name\":\"a\\\"b\"");
  assert(whisper_gateway::log_field("count", static_cast<uint64_t>(42)) ==
         ",\"count\":42");

  httplib::Response response;
  whisper_gateway::set_json(response, 418,
                            whisper_gateway::json_error("teapot"));
  assert(response.status == 418);
  assert(response.body == "{\"error\":\"teapot\"}");
  assert(response.get_header_value("Content-Type") == "application/json");
  assert(response.get_header_value("Access-Control-Allow-Origin") == "*");

  assert(whisper_gateway::lower_copy("AbC-XYZ") == "abc-xyz");
  assert(whisper_gateway::trim_copy("  value\r\n") == "value");
  uint64_t parsed = 0;
  assert(whisper_gateway::parse_u64("18446744073709551615", &parsed));
  assert(parsed == UINT64_MAX);
  assert(!whisper_gateway::parse_u64("18446744073709551616", &parsed));
  assert(whisper_gateway::extract_boundary(
             "multipart/form-data; boundary=raw+boundary._/") ==
         "raw+boundary._/");
  assert(whisper_gateway::extract_boundary(
             "multipart/form-data; boundary=bad boundary").empty());
  bool has_start = false;
  uint64_t pid = 0;
  uint64_t start = 0;
  assert(whisper_gateway::parse_pid_file_contents(
      "pid=123\nstart_epoch_ms=456\n", &pid, &start, &has_start));
  assert(pid == 123 && start == 456 && has_start);
  assert(whisper_gateway::shell_quote("a'b") == "'a'\\''b'");
  assert(whisper_gateway::command_output("/usr/bin/printf 'support-output\\n'") ==
         "support-output");
}

void test_time_and_deadline() {
  assert(!whisper_gateway::deadline_expired(whisper_gateway::TimePoint::max()));
  assert(whisper_gateway::deadline_expired(
      whisper_gateway::Clock::now() - std::chrono::milliseconds(1)));

  httplib::Client client("127.0.0.1", 1);
  assert(!whisper_gateway::configure_client_deadline(
      client, whisper_gateway::Clock::now() - std::chrono::milliseconds(1)));
  assert(whisper_gateway::configure_client_deadline(
      client, whisper_gateway::Clock::now() + std::chrono::seconds(1)));
  assert(whisper_gateway::configure_client_deadline(
      client, whisper_gateway::TimePoint::max(),
      std::chrono::milliseconds(25)));
  assert(!whisper_gateway::configure_client_deadline(
      client, whisper_gateway::TimePoint::max()));
}

void test_scope_exit_and_fds() {
  int scope_calls = 0;
  {
    auto first = whisper_gateway::make_scope_exit([&scope_calls] {
      ++scope_calls;
    });
    auto second = std::move(first);
    assert(!first.active());
    assert(second.active());
  }
  assert(scope_calls == 1);

  int descriptors[2] = {-1, -1};
  assert(::pipe(descriptors) == 0);
  whisper_gateway::ScopedFd read_fd(descriptors[0]);
  whisper_gateway::ScopedFd write_fd(descriptors[1]);
  const std::string payload = "fd payload";
  assert(whisper_gateway::write_all(write_fd.get(), payload));
  char buffer[32] = {};
  assert(::read(read_fd.get(), buffer, payload.size()) ==
         static_cast<ssize_t>(payload.size()));
  assert(std::string(buffer, payload.size()) == payload);

  const int released = write_fd.release();
  assert(!write_fd.valid());
  whisper_gateway::ScopedFd adopted(released);
  assert(adopted.valid());
}

void test_temp_upload_file() {
  char directory_template[] = "/tmp/whisper-support-unit-XXXXXX";
  char *directory = ::mkdtemp(directory_template);
  assert(directory != nullptr);

  whisper_gateway::TempUploadFile upload;
  assert(upload.create(directory));
  assert(upload.valid());
  const std::string path = upload.path();
  struct stat file_stat{};
  assert(::stat(path.c_str(), &file_stat) == 0);
  assert((file_stat.st_mode & 0777) == 0600);
  assert(whisper_gateway::regular_file(path));
  assert(whisper_gateway::regular_file_size(path) == 0);
  assert(whisper_gateway::write_all(upload.fd(), "upload", 6));
  assert(upload.close_fd());
  assert(whisper_gateway::regular_file_size(path) == 6);
  assert(whisper_gateway::sha256_file(path) ==
         "ff4085ad157354dc8ea67a848e7c2270b4a19282713cf3a7ecf8e0ffbb159ed1");
  std::ifstream file(path, std::ios::binary);
  std::string contents((std::istreambuf_iterator<char>(file)),
                       std::istreambuf_iterator<char>());
  assert(contents == "upload");
  file.close();
  assert(upload.unlink_path());
  assert(::access(path.c_str(), F_OK) != 0);
  assert(::rmdir(directory) == 0);
}

void test_bounded_thread_pool() {
  whisper_gateway::BoundedThreadPool pool(1, 1);
  std::mutex mutex;
  std::condition_variable condition;
  bool started = false;
  bool release = false;
  int completed = 0;

  assert(pool.enqueue([&] {
    std::unique_lock<std::mutex> lock(mutex);
    started = true;
    condition.notify_all();
    condition.wait(lock, [&release] { return release; });
  }));
  {
    std::unique_lock<std::mutex> lock(mutex);
    assert(condition.wait_for(lock, std::chrono::seconds(2),
                             [&started] { return started; }));
  }
  assert(pool.enqueue([&completed] { ++completed; }));
  assert(pool.queued_jobs() == 1);
  assert(!pool.enqueue([] {}));

  {
    std::lock_guard<std::mutex> lock(mutex);
    release = true;
  }
  condition.notify_all();
  pool.shutdown();
  assert(pool.shutting_down());
  assert(completed == 1);
  assert(!pool.enqueue([] {}));
}

} // namespace

int main() {
  test_json_and_http_helpers();
  test_time_and_deadline();
  test_scope_exit_and_fds();
  test_temp_upload_file();
  test_bounded_thread_pool();
  return 0;
}
