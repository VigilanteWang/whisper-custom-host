#ifndef WHISPER_CUSTOM_HOST_GATEWAY_CONFIG_H
#define WHISPER_CUSTOM_HOST_GATEWAY_CONFIG_H

#include <cstddef>
#include <cstdint>
#include <string>

namespace whisper_gateway {

// cpp-httplib needs a little room for the multipart framing around the file
// body.  Keep this in the configuration module so every caller performs the
// same checked addition instead of duplicating a potentially overflowing one.
constexpr uint64_t kUploadOverheadBytes = 1024ULL * 1024ULL;

struct Config {
  // The service topology is fixed: the gateway is the LAN-facing endpoint,
  // while whisper-server must remain loopback-only.  The backend host is not
  // read from the environment; the legacy CLI flag is accepted and checked
  // below so an old generated LaunchAgent cannot widen the backend scope.
  std::string gateway_host = "0.0.0.0";
  int gateway_port = 8080;
  std::string backend_host = "127.0.0.1";
  int backend_port = 18080;
  int idle_timeout_seconds = 300;
  int startup_timeout_seconds = 180;
  int shutdown_timeout_seconds = 15;
  int request_timeout_seconds = 900;
  int max_pending_requests = 4;
  uint64_t max_upload_bytes = 256ULL * 1024ULL * 1024ULL;
  // Checked value for cpp-httplib's total payload limit.  It is populated by
  // parse_args and is intentionally not an independently configurable value.
  uint64_t max_payload_bytes = 0;
  int start_failure_backoff_seconds = 10;

  std::string root_dir = ".";
  std::string source_dir;
  std::string server_bin;
  std::string model_file;
  std::string public_dir;
  std::string inference_path = "/v1/audio/transcriptions";
  std::string language = "auto";
  int threads = 4;
  std::string expected_commit;
  std::string httplib_header;
  uint64_t expected_model_size = 0;
  std::string expected_model_sha256;
  std::string upload_dir;
  std::string gateway_pid_file;
  std::string pid_file;
  std::string backend_log_file;
  std::string git_bin = "/usr/bin/git";
};

// Parse environment variables and command-line arguments into config.  The
// precedence is CLI > environment > defaults.  Root/source are finalized
// before any path whose default is derived from either one is constructed.
// Returns false and writes a Chinese diagnostic to error on invalid input.
bool parse_args(int argc, char **argv, Config *config, std::string *error);

// Kept separate so a caller can use the exact same help text for --help and
// for a usage error without knowing parser internals.
void print_help(const char *argv0);

// Return false if max_upload_bytes cannot safely be increased by the fixed
// multipart overhead or represented by size_t on this platform.
bool checked_payload_limit(uint64_t max_upload_bytes, uint64_t *payload_bytes,
                           std::string *error);

}  // namespace whisper_gateway

#endif  // WHISPER_CUSTOM_HOST_GATEWAY_CONFIG_H
