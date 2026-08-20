// A tiny whisper-server-compatible fixture used by the on-demand gateway
// integration tests.  It deliberately does not load a Whisper model.  The
// command line accepts the production whisper-server options that the gateway
// passes, while MOCK_* environment variables (or --mock-* options) control
// deterministic failure and latency modes.

#include "httplib.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <pthread.h>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

struct Options {
  std::string host = "127.0.0.1";
  int port = 18080;
  std::string inference_path = "/v1/audio/transcriptions";
  int startup_delay_ms = 0;
  int ready_delay_ms = 0;
  int request_delay_ms = 0;
  int crash_after = 0;
  int exit_after_ms = 0;
  std::string marker_file;
  std::string response_text = "mock transcription";
};

httplib::Server *g_server = nullptr;
std::atomic<bool> g_terminating{false};
std::mutex g_marker_mutex;
std::atomic<int> g_requests{0};

int parse_int(const std::string &value, const char *name) {
  char *end = nullptr;
  const long parsed = std::strtol(value.c_str(), &end, 10);
  if (end == value.c_str() || *end != '\0' || parsed < 0 || parsed > 86400000) {
    throw std::runtime_error(std::string("invalid ") + name + ": " + value);
  }
  return static_cast<int>(parsed);
}

std::string env_string(const char *name, std::string fallback) {
  const char *value = std::getenv(name);
  return value == nullptr ? fallback : std::string(value);
}

int env_int(const char *name, int fallback) {
  const char *value = std::getenv(name);
  return value == nullptr ? fallback : parse_int(value, name);
}

void marker(const Options &options, const std::string &event) {
  if (options.marker_file.empty()) {
    return;
  }
  std::lock_guard<std::mutex> lock(g_marker_mutex);
  std::ofstream out(options.marker_file, std::ios::app);
  if (out) {
    out << event << '\n';
    out.flush();
  }
}

bool is_option_with_value(const std::string &arg) {
  // These are the production whisper-server options which may carry a value.
  // The fixture accepts them so a gateway can pass its normal fixed command
  // line without a test-only wrapper or a shell parser.
  static const char *const options[] = {
      "--host",          "--port",          "--public",
      "--request-path",  "--inference-path", "--tmp-dir",
      "--threads",       "--processors",    "--model",
      "--language",      "--device",       "--offset-t",
      "--offset-n",      "--duration",     "--max-context",
      "--max-len",       "--best-of",      "--beam-size",
      "--audio-ctx",     "--word-thold",   "--entropy-thold",
      "--logprob-thold", "--no-speech-thold", "--prompt",
      "--ov-e-device",   "--dtw",          "--vad-model",
      "--vad-threshold", "--vad-min-speech-duration-ms",
      "--vad-min-silence-duration-ms", "--vad-max-speech-duration-s",
      "--vad-speech-pad-ms", "--vad-samples-overlap",
      "--mock-startup-delay-ms", "--mock-ready-delay-ms",
      "--mock-request-delay-ms", "--mock-crash-after",
      "--mock-exit-after-ms", "--mock-marker-file", "--mock-response-text",
  };
  for (const char *candidate : options) {
    if (arg == candidate) {
      return true;
    }
  }
  return false;
}

void parse_args(int argc, char **argv, Options &options) {
  options.host = env_string("MOCK_HOST", options.host);
  options.port = env_int("MOCK_PORT", options.port);
  options.inference_path =
      env_string("MOCK_INFERENCE_PATH", options.inference_path);
  options.startup_delay_ms = env_int("MOCK_STARTUP_DELAY_MS", 0);
  options.ready_delay_ms = env_int("MOCK_READY_DELAY_MS", 0);
  options.request_delay_ms = env_int("MOCK_REQUEST_DELAY_MS", 0);
  options.crash_after = env_int("MOCK_CRASH_AFTER", 0);
  options.exit_after_ms = env_int("MOCK_EXIT_AFTER_MS", 0);
  options.marker_file = env_string("MOCK_MARKER_FILE", "");
  options.response_text =
      env_string("MOCK_RESPONSE_TEXT", options.response_text);

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto require_value = [&](const char *name) -> std::string {
      if (i + 1 >= argc) {
        throw std::runtime_error(std::string("missing value for ") + name);
      }
      return argv[++i];
    };

    if (arg == "--host") {
      options.host = require_value("--host");
    } else if (arg == "--port") {
      options.port = parse_int(require_value("--port"), "--port");
    } else if (arg == "--inference-path") {
      options.inference_path = require_value("--inference-path");
    } else if (arg == "--mock-startup-delay-ms") {
      options.startup_delay_ms =
          parse_int(require_value("--mock-startup-delay-ms"),
                    "--mock-startup-delay-ms");
    } else if (arg == "--mock-ready-delay-ms") {
      options.ready_delay_ms =
          parse_int(require_value("--mock-ready-delay-ms"),
                    "--mock-ready-delay-ms");
    } else if (arg == "--mock-request-delay-ms") {
      options.request_delay_ms =
          parse_int(require_value("--mock-request-delay-ms"),
                    "--mock-request-delay-ms");
    } else if (arg == "--mock-crash-after") {
      options.crash_after =
          parse_int(require_value("--mock-crash-after"), "--mock-crash-after");
    } else if (arg == "--mock-exit-after-ms") {
      options.exit_after_ms =
          parse_int(require_value("--mock-exit-after-ms"),
                    "--mock-exit-after-ms");
    } else if (arg == "--mock-marker-file") {
      options.marker_file = require_value("--mock-marker-file");
    } else if (arg == "--mock-response-text") {
      options.response_text = require_value("--mock-response-text");
    } else if (arg == "--public" || arg == "--request-path" ||
               arg == "--tmp-dir" || arg == "--threads" ||
               arg == "--processors" || arg == "--model" ||
               arg == "--language" || arg == "--device" ||
               arg == "--offset-t" || arg == "--offset-n" ||
               arg == "--duration" || arg == "--max-context" ||
               arg == "--max-len" || arg == "--best-of" ||
               arg == "--beam-size" || arg == "--audio-ctx" ||
               arg == "--word-thold" || arg == "--entropy-thold" ||
               arg == "--logprob-thold" || arg == "--no-speech-thold" ||
               arg == "--prompt" || arg == "--ov-e-device" ||
               arg == "--dtw" || arg == "--vad-model" ||
               arg == "--vad-threshold" ||
               arg == "--vad-min-speech-duration-ms" ||
               arg == "--vad-min-silence-duration-ms" ||
               arg == "--vad-max-speech-duration-s" ||
               arg == "--vad-speech-pad-ms" ||
               arg == "--vad-samples-overlap") {
      // Consume a production value but intentionally do not use it.
      (void)require_value(arg.c_str());
    } else if (arg == "--convert" || arg == "--no-gpu" ||
               arg == "--flash-attn" || arg == "--no-flash-attn" ||
               arg == "--vad" || arg == "--no-language-probabilities" ||
               arg == "--debug-mode" || arg == "--translate" ||
               arg == "--no-timestamps" || arg == "--suppress-nst" ||
               arg == "--diarize" || arg == "--tinydiarize" ||
               arg == "--no-fallback" || arg == "--print-special" ||
               arg == "--print-colors" || arg == "--print-realtime" ||
               arg == "--print-progress" || arg == "--detect-language") {
      // Production boolean flag; no action needed.
    } else if (arg == "--help" || arg == "-h") {
      std::cout
          << "mock-whisper-server: accepts whisper-server options plus "
             "--mock-startup-delay-ms, --mock-ready-delay-ms, "
             "--mock-request-delay-ms, --mock-crash-after, "
             "--mock-exit-after-ms, --mock-marker-file, "
             "--mock-response-text\n";
      std::exit(0);
    } else if (arg.rfind("--", 0) == 0 && i + 1 < argc &&
               std::string(argv[i + 1]).rfind("-", 0) != 0 &&
               !is_option_with_value(arg)) {
      // Be liberal with future production options.  If an unknown long option
      // is followed by a non-option value, consume that value as well.
      ++i;
    }
  }

  if (options.port <= 0 || options.port > 65535) {
    throw std::runtime_error("mock port must be between 1 and 65535");
  }
  if (options.inference_path.empty() || options.inference_path[0] != '/') {
    throw std::runtime_error("mock inference path must start with '/'");
  }
}

void set_json_response(httplib::Response &res, const std::string &text) {
  res.set_content(std::string("{\"text\":\"") + text + "\"}",
                  "application/json");
}

}  // namespace

int main(int argc, char **argv) {
  Options options;
  try {
    parse_args(argc, argv, options);
  } catch (const std::exception &error) {
    std::cerr << "mock-whisper-server: " << error.what() << '\n';
    return 2;
  }

  marker(options, "start");
  httplib::Server server;
  g_server = &server;

  // The gateway blocks lifecycle signals before posix_spawn.  A real
  // whisper-server should reset that mask in the child; the fixture handles
  // both launch styles so tests can still terminate it deterministically.
  sigset_t signal_set;
  sigemptyset(&signal_set);
  sigaddset(&signal_set, SIGINT);
  sigaddset(&signal_set, SIGTERM);
  sigaddset(&signal_set, SIGUSR1);
  ::pthread_sigmask(SIG_BLOCK, &signal_set, nullptr);
  std::thread signal_thread([&signal_set]() {
    int signal = 0;
    if (::sigwait(&signal_set, &signal) == 0 && signal != SIGUSR1) {
      g_terminating.store(true);
      if (g_server != nullptr) {
        g_server->stop();
      }
    }
  });

  if (options.startup_delay_ms > 0) {
    std::this_thread::sleep_for(
        std::chrono::milliseconds(options.startup_delay_ms));
  }
  if (g_terminating.load()) {
    ::pthread_kill(signal_thread.native_handle(), SIGUSR1);
    signal_thread.join();
    g_server = nullptr;
    return 143;
  }

  server.set_read_timeout(30);
  server.set_write_timeout(30);
  server.set_payload_max_length(512 * 1024 * 1024);

  const auto ready_at = Clock::now() +
                        std::chrono::milliseconds(options.ready_delay_ms);
  const auto is_ready = [&]() { return Clock::now() >= ready_at; };

  server.Get("/health", [&](const httplib::Request &, httplib::Response &res) {
    if (!is_ready()) {
      res.status = 503;
      res.set_content("{\"status\":\"loading\"}", "application/json");
      return;
    }
    res.status = 200;
    res.set_content("{\"status\":\"ok\"}", "application/json");
  });

  server.Options(options.inference_path,
                 [](const httplib::Request &, httplib::Response &res) {
                   res.status = 204;
                   res.set_header("Access-Control-Allow-Origin", "*");
                   res.set_header("Access-Control-Allow-Methods", "POST, OPTIONS");
                   res.set_header("Access-Control-Allow-Headers", "Content-Type, Authorization");
                 });

  server.Post(options.inference_path,
              [&](const httplib::Request &req, httplib::Response &res) {
                if (!is_ready()) {
                  res.status = 503;
                  res.set_content("{\"error\":\"loading\"}",
                                  "application/json");
                  return;
                }

                const int request_number = ++g_requests;
                marker(options, "request " + std::to_string(request_number));
                if (options.crash_after > 0 &&
                    request_number >= options.crash_after) {
                  marker(options, "crash");
                  std::_Exit(42);
                }

                if (options.request_delay_ms > 0) {
                  std::this_thread::sleep_for(
                      std::chrono::milliseconds(options.request_delay_ms));
                }

                // The fixture only records the size, never the uploaded audio.
                marker(options, "body-bytes " + std::to_string(req.body.size()));
                if (req.has_header("X-Request-Id")) {
                  marker(options, "request-id " + req.get_header_value("X-Request-Id"));
                }
                res.status = 200;
                set_json_response(res, options.response_text);
              });

  // This is intentionally a process-level crash, useful for checking that a
  // gateway reports 502/backoff and never adopts an unrelated process.
  if (options.exit_after_ms > 0) {
    std::thread([&options]() {
      std::this_thread::sleep_for(
          std::chrono::milliseconds(options.exit_after_ms));
      if (!g_terminating.load()) {
        marker(options, "crash");
        std::_Exit(43);
      }
    }).detach();
  }

  const bool listened = server.listen(options.host.c_str(), options.port);
  g_terminating.store(true);
  ::pthread_kill(signal_thread.native_handle(), SIGUSR1);
  signal_thread.join();
  g_server = nullptr;
  if (!listened && !g_terminating.load()) {
    marker(options, "listen-failed");
    return 1;
  }
  marker(options, "stop");
  return g_terminating.load() ? 143 : 0;
}
