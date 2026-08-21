#pragma once

#include "backend_controller.h"

#include "httplib.h"

#include <atomic>
#include <cstdint>
#include <string>
#include <thread>

#include <signal.h>

namespace whisper_gateway {

class HttpGateway final {
public:
  explicit HttpGateway(Config config);
  HttpGateway(const HttpGateway &) = delete;
  HttpGateway &operator=(const HttpGateway &) = delete;
  ~HttpGateway();

  bool validate_startup(std::string *error);
  int run();

private:
  void handle_health(const httplib::Request &, httplib::Response &response);
  void handle_ready(const httplib::Request &, httplib::Response &response);
  void handle_options(const httplib::Request &, httplib::Response &response);
  void handle_post(const httplib::Request &request,
                   httplib::Response &response,
                   const httplib::ContentReader &reader);
  bool validate_request(const httplib::Request &request,
                        httplib::Response &response);
  bool forward_file(const httplib::Request &request,
                    const std::string &request_id,
                    const std::string &file_path, std::uint64_t file_size,
                    const std::string &content_type, TimePoint deadline,
                    httplib::Response &response);
  void set_error(httplib::Response &response, int status,
                 const std::string &message,
                 const std::string &retry_after = {});
  std::string make_request_id();
  void signal_loop();
  bool write_gateway_pid_file();
  void remove_gateway_pid_file();

  BackendController controller_;
  httplib::Server server_;
  std::atomic<std::uint64_t> request_counter_{0};
  std::thread signal_thread_;
  sigset_t signal_set_{};
};

} // namespace whisper_gateway
