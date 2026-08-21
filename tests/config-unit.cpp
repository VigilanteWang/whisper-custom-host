#include "../gateway/config.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace {

using whisper_gateway::Config;

const char *const kEnvironmentNames[] = {
    "WHISPER_GATEWAY_PORT",
    "WHISPER_BACKEND_PORT",
    "WHISPER_IDLE_TIMEOUT_SECONDS",
    "WHISPER_STARTUP_TIMEOUT_SECONDS",
    "WHISPER_SHUTDOWN_TIMEOUT_SECONDS",
    "WHISPER_REQUEST_TIMEOUT_SECONDS",
    "WHISPER_MAX_PENDING_REQUESTS",
    "WHISPER_MAX_UPLOAD_BYTES",
    "WHISPER_START_FAILURE_BACKOFF_SECONDS",
    "WHISPER_THREADS",
    "WHISPER_MODEL_SIZE_BYTES",
    "WHISPER_INSTALL_ROOT",
    "WHISPER_PROJECT_ROOT",
    "WHISPER_SOURCE_DIR",
    "WHISPER_SERVER_BIN",
    "WHISPER_BACKEND_BIN",
    "WHISPER_MODEL_FILE",
    "WHISPER_MODEL_PATH",
    "WHISPER_APP_SUPPORT_ROOT",
    "WHISPER_PUBLIC_DIR",
    "WHISPER_INFERENCE_PATH",
    "WHISPER_LANGUAGE",
    "WHISPER_HTTPLIB_HEADER",
    "WHISPER_COMMIT",
    "WHISPER_MODEL_SHA256",
    "WHISPER_UPLOAD_DIR",
    "WHISPER_GATEWAY_PID_FILE",
    "WHISPER_ON_DEMAND_PID_FILE",
    "WHISPER_BACKEND_PID_FILE",
    "WHISPER_ON_DEMAND_BACKEND_LOG",
    "WHISPER_BACKEND_LOG_FILE",
};

void clear_environment() {
  for (const char *name : kEnvironmentNames) unsetenv(name);
}

bool parse(const std::vector<std::string> &arguments, Config *config,
           std::string *error) {
  std::vector<char *> argv;
  argv.reserve(arguments.size());
  for (const std::string &argument : arguments) {
    argv.push_back(const_cast<char *>(argument.c_str()));
  }
  return whisper_gateway::parse_args(static_cast<int>(argv.size()), argv.data(),
                                     config, error);
}

void require(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "config-unit: " << message << '\n';
    std::exit(1);
  }
}

void require_failure(const std::vector<std::string> &arguments,
                     const char *message) {
  Config config;
  std::string error;
  require(!parse(arguments, &config, &error), message);
  require(!error.empty(), "failed parse must provide a diagnostic");
}

void test_defaults_and_checked_payload() {
  clear_environment();
  setenv("HOME", "/tmp/whisper-config-home", 1);
  Config config;
  std::string error;
  require(parse({"gateway"}, &config, &error), "default config parses");
  require(config.gateway_port == 8080 && config.backend_port == 18080,
          "default ports preserved");
  require(config.root_dir == ".", "default root preserved");
  require(config.source_dir.find("third_party/whisper.cpp") != std::string::npos,
          "source derives from default root");
  require(config.server_bin.find("build/whisper.cpp/bin/whisper-server") !=
              std::string::npos,
          "server binary derives from default root");
  require(config.model_file ==
              "/tmp/whisper-config-home/Library/Application Support/"
              "whisper-custom-host/runtime/models/ggml-large-v3-turbo.bin",
          "model defaults to Application Support authority");
  require(config.max_payload_bytes == config.max_upload_bytes +
              whisper_gateway::kUploadOverheadBytes,
          "payload limit includes checked overhead");

  uint64_t payload = 0;
  require(!whisper_gateway::checked_payload_limit(
              std::numeric_limits<uint64_t>::max(), &payload, &error),
          "uint64 payload addition overflow rejected");
  require(!whisper_gateway::checked_payload_limit(
              0, &payload, &error),
          "zero upload limit rejected");
}

void test_precedence_and_rederivation() {
  clear_environment();
  setenv("HOME", "/tmp/whisper-config-home", 1);
  setenv("WHISPER_INSTALL_ROOT", "/tmp/env-root", 1);
  setenv("WHISPER_SOURCE_DIR", "/tmp/env-source", 1);
  setenv("WHISPER_GATEWAY_PORT", "9001", 1);
  setenv("WHISPER_SERVER_BIN", "/tmp/env-server", 1);
  Config config;
  std::string error;
  require(parse({"gateway", "--root-dir", "/tmp/cli-root",
                 "--gateway-port", "9002"},
                &config, &error),
          "CLI overrides environment");
  require(config.root_dir == "/tmp/cli-root", "CLI root wins");
  require(config.gateway_port == 9002, "CLI scalar wins");
  require(config.source_dir.find("/tmp/env-source") != std::string::npos,
          "explicit source is retained");
  require(config.server_bin.find("/tmp/env-server") != std::string::npos,
          "explicit server is retained");

  clear_environment();
  require(parse({"gateway", "--root-dir", "/tmp/cli-root",
                 "--source-dir", "/tmp/cli-source"},
                &config, &error),
          "explicit source config parses");
  require(config.source_dir.find("/tmp/cli-source") != std::string::npos,
          "CLI source wins");
  require(config.public_dir.find("/tmp/cli-source/examples/server/public") !=
              std::string::npos,
          "public path derives from final CLI source");
  require(config.httplib_header.find("/tmp/cli-source/examples/server/httplib.h") !=
              std::string::npos,
          "header path derives from final CLI source");
  require(config.server_bin.find("/tmp/cli-root/build/whisper.cpp/bin/whisper-server") !=
              std::string::npos,
          "server path derives from final CLI root");
  require(config.model_file ==
              "/tmp/whisper-config-home/Library/Application Support/"
              "whisper-custom-host/runtime/models/ggml-large-v3-turbo.bin",
          "model authority does not move with CLI root");

  clear_environment();
  setenv("WHISPER_APP_SUPPORT_ROOT", "/tmp/custom-app-support", 1);
  require(parse({"gateway", "--root-dir", "/tmp/another-root"},
                &config, &error),
          "Application Support override parses");
  require(config.model_file ==
              "/tmp/custom-app-support/runtime/models/ggml-large-v3-turbo.bin",
          "Application Support override owns default model path");
}

void test_aliases_and_ranges() {
  clear_environment();
  setenv("WHISPER_BACKEND_BIN", "/tmp/backend-alias", 1);
  setenv("WHISPER_MODEL_PATH", "/tmp/model-alias", 1);
  setenv("WHISPER_BACKEND_PID_FILE", "/tmp/backend.pid", 1);
  setenv("WHISPER_BACKEND_LOG_FILE", "/tmp/backend.log", 1);
  Config config;
  std::string error;
  require(parse({"gateway", "--backend-bin", "/tmp/cli-backend",
                 "--source-commit", "abc", "--pid-file", "/tmp/cli.pid"},
                &config, &error),
          "compatibility aliases parse");
  require(config.server_bin.find("/tmp/cli-backend") != std::string::npos,
          "backend-bin alias works");
  require(config.expected_commit == "abc", "source-commit alias works");
  require(config.model_file.find("/tmp/model-alias") != std::string::npos,
          "model-path alias works");
  require(config.pid_file.find("/tmp/cli.pid") != std::string::npos,
          "pid-file alias wins");
  require(config.backend_log_file.find("/tmp/backend.log") != std::string::npos,
          "backend-log environment alias works");

  clear_environment();
  require_failure({"gateway", "--gateway-port", "0"},
                  "zero gateway port rejected");
  require_failure({"gateway", "--gateway-port", "65536"},
                  "out-of-range gateway port rejected");
  require_failure({"gateway", "--idle-timeout-seconds", "0"},
                  "zero timeout rejected");
  require_failure({"gateway", "--request-timeout-seconds", "86401"},
                  "overlong timeout rejected");
  require_failure({"gateway", "--max-pending-requests", "1025"},
                  "oversized queue rejected");
  require_failure({"gateway", "--threads", "257"},
                  "oversized thread count rejected");
  require_failure({"gateway", "--backend-host", "0.0.0.0"},
                  "non-loopback backend rejected");
  require_failure({"gateway", "--gateway-port", "18080"},
                  "duplicate ports rejected");
}

}  // namespace

int main() {
  test_defaults_and_checked_payload();
  test_precedence_and_rederivation();
  test_aliases_and_ranges();
  std::cout << "config-unit: all tests passed\n";
  return 0;
}
