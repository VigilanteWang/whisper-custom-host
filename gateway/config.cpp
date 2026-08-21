#include "config.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstdio>
#include <limits>
#include <limits.h>
#include <string_view>
#include <unistd.h>

namespace whisper_gateway {
namespace {

constexpr int kMinPort = 1;
constexpr int kMaxPort = 65535;

// These upper bounds match scripts/lib/common.sh.  They prevent an
// accidentally valid int from turning into an unreasonably long wait or an
// unbounded queue, while retaining the old positive/non-negative semantics.
constexpr int kMaxIdleTimeoutSeconds = 604800;
constexpr int kMaxStartupTimeoutSeconds = 86400;
constexpr int kMaxShutdownTimeoutSeconds = 3600;
constexpr int kMaxRequestTimeoutSeconds = 86400;
constexpr int kMaxPendingRequests = 1024;
constexpr int kMaxThreads = 256;
constexpr int kMaxBackoffSeconds = 86400;
constexpr uint64_t kMaxModelSizeBytes = 1099511627776ULL;
constexpr uint64_t kMaxUploadBytes = 1099511627776ULL;

bool parse_u64(std::string_view value, uint64_t *out) {
  if (out == nullptr || value.empty()) return false;
  uint64_t result = 0;
  for (const char raw : value) {
    const unsigned char c = static_cast<unsigned char>(raw);
    if (!std::isdigit(c)) return false;
    const uint64_t digit = static_cast<uint64_t>(c - '0');
    if (result > (std::numeric_limits<uint64_t>::max() - digit) / 10) {
      return false;
    }
    result = result * 10 + digit;
  }
  *out = result;
  return true;
}

bool parse_positive_int(std::string_view value, int *out) {
  uint64_t parsed = 0;
  if (!parse_u64(value, &parsed) || parsed == 0 ||
      parsed > static_cast<uint64_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  *out = static_cast<int>(parsed);
  return true;
}

bool parse_nonnegative_int(std::string_view value, int *out) {
  uint64_t parsed = 0;
  if (!parse_u64(value, &parsed) ||
      parsed > static_cast<uint64_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  *out = static_cast<int>(parsed);
  return true;
}

const char *environment_value(const char *name) {
  const char *value = std::getenv(name);
  return value == nullptr || *value == '\0' ? nullptr : value;
}

std::string environment_or(const char *name, const std::string &fallback) {
  const char *value = environment_value(name);
  return value == nullptr ? fallback : std::string(value);
}

std::string environment_alias_or(const char *primary, const char *alias,
                                 const std::string &fallback) {
  const char *value = environment_value(primary);
  if (value != nullptr) return value;
  return environment_or(alias, fallback);
}

std::string default_model_file() {
  const char *app_support_root = environment_value("WHISPER_APP_SUPPORT_ROOT");
  if (app_support_root != nullptr) {
    return std::string(app_support_root) +
           "/runtime/models/ggml-large-v3-turbo.bin";
  }
  const char *home = environment_value("HOME");
  if (home == nullptr) return {};
  return std::string(home) +
         "/Library/Application Support/whisper-custom-host/runtime/models/"
         "ggml-large-v3-turbo.bin";
}

std::string canonical_or(const std::string &path) {
  if (path.empty()) return path;
  char resolved[PATH_MAX];
  if (::realpath(path.c_str(), resolved) != nullptr) return resolved;
  return path;
}

bool contains_whitespace(std::string_view value) {
  return std::any_of(value.begin(), value.end(), [](char raw) {
    return std::isspace(static_cast<unsigned char>(raw)) != 0;
  });
}

bool parse_env_positive(const char *name, int *target, std::string *error) {
  const char *value = environment_value(name);
  if (value == nullptr) return true;
  int parsed = 0;
  if (!parse_positive_int(value, &parsed)) {
    *error = std::string("环境变量无效：") + name;
    return false;
  }
  *target = parsed;
  return true;
}

bool parse_env_nonnegative(const char *name, int *target, std::string *error) {
  const char *value = environment_value(name);
  if (value == nullptr) return true;
  int parsed = 0;
  if (!parse_nonnegative_int(value, &parsed)) {
    *error = std::string("环境变量无效：") + name;
    return false;
  }
  *target = parsed;
  return true;
}

bool parse_env_u64(const char *name, uint64_t *target, std::string *error) {
  const char *value = environment_value(name);
  if (value == nullptr) return true;
  uint64_t parsed = 0;
  if (!parse_u64(value, &parsed) || parsed == 0) {
    *error = std::string("环境变量无效：") + name;
    return false;
  }
  *target = parsed;
  return true;
}

bool take_value(int argc, char **argv, int *index, const std::string &arg,
                std::string *value, std::string *error) {
  if (*index + 1 >= argc) {
    *error = "选项缺少值：" + arg;
    return false;
  }
  *value = argv[++(*index)];
  return true;
}

bool parse_positive_option(int argc, char **argv, int *index,
                          const std::string &arg, int *target,
                          const char *error_prefix, std::string *error) {
  std::string value;
  if (!take_value(argc, argv, index, arg, &value, error)) return false;
  if (!parse_positive_int(value, target)) {
    *error = std::string(error_prefix) + value;
    return false;
  }
  return true;
}

bool parse_nonnegative_option(int argc, char **argv, int *index,
                             const std::string &arg, int *target,
                             const char *error_prefix, std::string *error) {
  std::string value;
  if (!take_value(argc, argv, index, arg, &value, error)) return false;
  if (!parse_nonnegative_int(value, target)) {
    *error = std::string(error_prefix) + value;
    return false;
  }
  return true;
}

bool parse_u64_option(int argc, char **argv, int *index, const std::string &arg,
                     uint64_t *target, const char *error_prefix,
                     std::string *error) {
  std::string value;
  if (!take_value(argc, argv, index, arg, &value, error)) return false;
  if (!parse_u64(value, target) || *target == 0) {
    *error = std::string(error_prefix) + value;
    return false;
  }
  return true;
}

bool validate_range(const Config &config, std::string *error) {
  if (config.backend_host != "127.0.0.1") {
    *error = "后端地址必须为 127.0.0.1";
    return false;
  }
  if (config.gateway_port < kMinPort || config.gateway_port > kMaxPort ||
      config.backend_port < kMinPort || config.backend_port > kMaxPort ||
      config.gateway_port == config.backend_port) {
    *error = "网关和后端端口必须在 1-65535 且不能相同";
    return false;
  }
  if (config.root_dir.empty() || config.source_dir.empty() ||
      config.server_bin.empty() || config.model_file.empty() ||
      config.public_dir.empty() || config.upload_dir.empty() ||
      config.gateway_pid_file.empty() || config.pid_file.empty() ||
      config.backend_log_file.empty()) {
    *error = "路径配置不能为空";
    return false;
  }
  if (config.inference_path.empty() || config.inference_path.front() != '/' ||
      contains_whitespace(config.inference_path)) {
    *error = "inference path 必须是无空白的绝对 HTTP 路径";
    return false;
  }
  if (config.idle_timeout_seconds < 1 ||
      config.idle_timeout_seconds > kMaxIdleTimeoutSeconds ||
      config.startup_timeout_seconds < 1 ||
      config.startup_timeout_seconds > kMaxStartupTimeoutSeconds ||
      config.shutdown_timeout_seconds < 1 ||
      config.shutdown_timeout_seconds > kMaxShutdownTimeoutSeconds ||
      config.request_timeout_seconds < 1 ||
      config.request_timeout_seconds > kMaxRequestTimeoutSeconds) {
    *error = "超时必须在允许范围内";
    return false;
  }
  if (config.max_pending_requests < 1 ||
      config.max_pending_requests > kMaxPendingRequests) {
    *error = "max pending requests 必须在 1-1024";
    return false;
  }
  if (config.threads < 1 || config.threads > kMaxThreads) {
    *error = "线程数必须在 1-256";
    return false;
  }
  if (config.start_failure_backoff_seconds < 0 ||
      config.start_failure_backoff_seconds > kMaxBackoffSeconds) {
    *error = "启动失败退避秒数必须在 0-86400";
    return false;
  }
  if (config.expected_model_size > kMaxModelSizeBytes) {
    *error = "模型大小超出允许范围";
    return false;
  }
  if (config.max_upload_bytes > kMaxUploadBytes) {
    *error = "上传大小超出允许范围";
    return false;
  }
  uint64_t payload_bytes = 0;
  if (!checked_payload_limit(config.max_upload_bytes, &payload_bytes, error)) {
    return false;
  }
  return true;
}

}  // namespace

bool checked_payload_limit(uint64_t max_upload_bytes, uint64_t *payload_bytes,
                           std::string *error) {
  if (payload_bytes == nullptr) {
    if (error != nullptr) *error = "payload limit 输出参数为空";
    return false;
  }
  if (max_upload_bytes == 0 ||
      max_upload_bytes > std::numeric_limits<uint64_t>::max() -
                              kUploadOverheadBytes) {
    if (error != nullptr) *error = "上传大小与 multipart 开销相加溢出";
    return false;
  }
  const uint64_t result = max_upload_bytes + kUploadOverheadBytes;
  if (result > static_cast<uint64_t>(std::numeric_limits<std::size_t>::max())) {
    if (error != nullptr) *error = "上传大小超出平台 payload 上限";
    return false;
  }
  *payload_bytes = result;
  return true;
}

void print_help(const char *argv0) {
  std::printf(
      "用法：%s [选项]\n\n"
      "网关：\n"
      "  --gateway-host HOST                 监听地址（正式服务固定 0.0.0.0；测试可覆盖）\n"
      "  --gateway-port PORT                 监听端口（默认 8080）\n"
      "  --backend-host HOST                 旧参数，仅接受 127.0.0.1，不进入 .env\n"
      "  --backend-port PORT                 后端端口（默认 18080）\n"
      "  --idle-timeout-seconds N            空闲回收秒数（默认 300）\n"
      "  --startup-timeout-seconds N         后端启动超时（默认 180）\n"
      "  --shutdown-timeout-seconds N        后端退出超时（默认 15）\n"
      "  --request-timeout-seconds N         单个请求超时（默认 900）\n"
      "  --max-pending-requests N            最大活动/等待请求数（默认 4）\n"
      "  --max-upload-bytes N                最大上传字节数（默认 268435456）\n"
      "  --start-failure-backoff-seconds N   启动失败退避秒数（默认 10）\n\n"
      "固定后端：\n"
      "  --root-dir DIR                      项目根目录\n"
      "  --source-dir DIR                    whisper.cpp 源码目录\n"
      "  --server-bin PATH                   whisper-server 绝对路径\n"
      "  --model PATH                        模型绝对路径\n"
      "  --public-dir DIR                    后端 public 目录（兼容保留）\n"
      "  --inference-path PATH               后端转写路径\n"
      "  --language LANG                     后端语言参数\n"
      "  --threads N                         后端线程数\n"
      "  --expected-commit SHA               要求的 whisper.cpp commit\n"
      "  --source-commit SHA                 --expected-commit 的兼容别名\n"
      "  --httplib-header PATH                固定 httplib.h 路径\n"
      "  --model-size N                      模型大小（字节）\n"
      "  --model-sha256 SHA                  模型 SHA-256\n"
      "  --upload-dir DIR                    上传临时目录\n"
      "  --gateway-pid-file PATH             网关 PID 文件\n"
      "  --backend-bin PATH                  --server-bin 的兼容别名\n"
      "  --pid-file PATH                     后端身份记录文件\n"
      "  --backend-pid-file PATH             --pid-file 的兼容别名\n"
      "  --backend-log-file PATH             后端日志文件\n"
      "  --help                              显示帮助\n",
      argv0 == nullptr ? "whisper-on-demand-gateway" : argv0);
}

bool parse_args(int argc, char **argv, Config *config, std::string *error) {
  if (config == nullptr || error == nullptr) return false;
  error->clear();

  Config &c = *config;

  // Scalar environment values are loaded first.  CLI values below are then
  // unconditionally applied, providing the documented CLI > env precedence.
  if (!parse_env_positive("WHISPER_GATEWAY_PORT", &c.gateway_port, error) ||
      !parse_env_positive("WHISPER_BACKEND_PORT", &c.backend_port, error) ||
      !parse_env_positive("WHISPER_IDLE_TIMEOUT_SECONDS",
                          &c.idle_timeout_seconds, error) ||
      !parse_env_positive("WHISPER_STARTUP_TIMEOUT_SECONDS",
                          &c.startup_timeout_seconds, error) ||
      !parse_env_positive("WHISPER_SHUTDOWN_TIMEOUT_SECONDS",
                          &c.shutdown_timeout_seconds, error) ||
      !parse_env_positive("WHISPER_REQUEST_TIMEOUT_SECONDS",
                          &c.request_timeout_seconds, error) ||
      !parse_env_positive("WHISPER_MAX_PENDING_REQUESTS",
                          &c.max_pending_requests, error) ||
      !parse_env_u64("WHISPER_MAX_UPLOAD_BYTES", &c.max_upload_bytes, error) ||
      !parse_env_nonnegative("WHISPER_START_FAILURE_BACKOFF_SECONDS",
                             &c.start_failure_backoff_seconds, error) ||
      !parse_env_positive("WHISPER_THREADS", &c.threads, error)) {
    return false;
  }

  const char *model_size_env = environment_value("WHISPER_MODEL_SIZE_BYTES");
  if (model_size_env != nullptr &&
      (!parse_u64(model_size_env, &c.expected_model_size) ||
       c.expected_model_size == 0)) {
    *error = "环境变量无效：WHISPER_MODEL_SIZE_BYTES";
    return false;
  }

  c.root_dir = environment_alias_or("WHISPER_INSTALL_ROOT",
                                    "WHISPER_PROJECT_ROOT", c.root_dir);
  const char *source_env = environment_value("WHISPER_SOURCE_DIR");
  const char *server_env = environment_value("WHISPER_SERVER_BIN");
  const char *backend_bin_env = environment_value("WHISPER_BACKEND_BIN");
  const char *model_env = environment_value("WHISPER_MODEL_FILE");
  const char *model_path_env = environment_value("WHISPER_MODEL_PATH");
  const char *public_env = environment_value("WHISPER_PUBLIC_DIR");
  const char *header_env = environment_value("WHISPER_HTTPLIB_HEADER");
  const char *upload_env = environment_value("WHISPER_UPLOAD_DIR");
  const char *gateway_pid_env = environment_value("WHISPER_GATEWAY_PID_FILE");
  const char *ondemand_pid_env = environment_value("WHISPER_ON_DEMAND_PID_FILE");
  const char *backend_pid_env = environment_value("WHISPER_BACKEND_PID_FILE");
  const char *ondemand_log_env = environment_value("WHISPER_ON_DEMAND_BACKEND_LOG");
  const char *backend_log_env = environment_value("WHISPER_BACKEND_LOG_FILE");

  c.inference_path = environment_or("WHISPER_INFERENCE_PATH", c.inference_path);
  c.language = environment_or("WHISPER_LANGUAGE", c.language);
  c.expected_commit = environment_or("WHISPER_COMMIT", c.expected_commit);
  c.expected_model_sha256 =
      environment_or("WHISPER_MODEL_SHA256", c.expected_model_sha256);

  bool source_cli = false;
  bool server_cli = false;
  bool model_cli = false;
  bool public_cli = false;
  bool header_cli = false;
  bool upload_cli = false;
  bool gateway_pid_cli = false;
  bool pid_cli = false;
  bool log_cli = false;

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") {
      print_help(argv[0]);
      std::exit(0);
    }

    std::string value;
    if (arg == "--gateway-host") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.gateway_host = value;
    } else if (arg == "--gateway-port") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.gateway_port, "端口无效：", error)) return false;
    } else if (arg == "--backend-host") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.backend_host = value;
    } else if (arg == "--backend-port") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.backend_port, "端口无效：", error)) return false;
    } else if (arg == "--idle-timeout-seconds") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.idle_timeout_seconds, "数值无效：", error)) return false;
    } else if (arg == "--startup-timeout-seconds") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.startup_timeout_seconds, "数值无效：", error)) return false;
    } else if (arg == "--shutdown-timeout-seconds") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.shutdown_timeout_seconds, "数值无效：", error)) return false;
    } else if (arg == "--request-timeout-seconds") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.request_timeout_seconds, "数值无效：", error)) return false;
    } else if (arg == "--max-pending-requests") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.max_pending_requests, "数值无效：", error)) return false;
    } else if (arg == "--max-upload-bytes") {
      if (!parse_u64_option(argc, argv, &i, arg, &c.max_upload_bytes, "数值无效：", error)) return false;
    } else if (arg == "--start-failure-backoff-seconds") {
      if (!parse_nonnegative_option(argc, argv, &i, arg, &c.start_failure_backoff_seconds, "数值无效：", error)) return false;
    } else if (arg == "--root-dir") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.root_dir = value;
    } else if (arg == "--source-dir") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.source_dir = value;
      source_cli = true;
    } else if (arg == "--server-bin" || arg == "--backend-bin") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.server_bin = value;
      server_cli = true;
    } else if (arg == "--model") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.model_file = value;
      model_cli = true;
    } else if (arg == "--public-dir") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.public_dir = value;
      public_cli = true;
    } else if (arg == "--inference-path") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.inference_path = value;
    } else if (arg == "--language") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.language = value;
    } else if (arg == "--threads") {
      if (!parse_positive_option(argc, argv, &i, arg, &c.threads, "数值无效：", error)) return false;
    } else if (arg == "--expected-commit" || arg == "--source-commit") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.expected_commit = value;
    } else if (arg == "--httplib-header") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.httplib_header = value;
      header_cli = true;
    } else if (arg == "--model-size") {
      if (!parse_u64_option(argc, argv, &i, arg, &c.expected_model_size, "模型大小无效：", error)) return false;
    } else if (arg == "--model-sha256") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.expected_model_sha256 = value;
    } else if (arg == "--upload-dir") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.upload_dir = value;
      upload_cli = true;
    } else if (arg == "--gateway-pid-file") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.gateway_pid_file = value;
      gateway_pid_cli = true;
    } else if (arg == "--backend-pid-file" || arg == "--pid-file") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.pid_file = value;
      pid_cli = true;
    } else if (arg == "--backend-log-file") {
      if (!take_value(argc, argv, &i, arg, &value, error)) return false;
      c.backend_log_file = value;
      log_cli = true;
    } else {
      *error = "未知选项：" + arg;
      return false;
    }
  }

  // Derive only after root/source and all CLI overrides have settled.  An
  // explicit value from either environment or CLI is never overwritten.
  if (!source_cli && source_env == nullptr) {
    c.source_dir = c.root_dir + "/third_party/whisper.cpp";
  } else if (!source_cli && source_env != nullptr) {
    c.source_dir = source_env;
  }
  if (!server_cli && server_env == nullptr && backend_bin_env == nullptr) {
    c.server_bin = c.root_dir + "/build/whisper.cpp/bin/whisper-server";
  } else if (!server_cli && server_env == nullptr && backend_bin_env != nullptr) {
    c.server_bin = backend_bin_env;
  } else if (!server_cli && server_env != nullptr) {
    c.server_bin = server_env;
  }
  if (!model_cli && model_env == nullptr && model_path_env == nullptr) {
    c.model_file = default_model_file();
  } else if (!model_cli && model_env == nullptr && model_path_env != nullptr) {
    c.model_file = model_path_env;
  } else if (!model_cli && model_env != nullptr) {
    c.model_file = model_env;
  }
  if (!public_cli && public_env == nullptr) {
    c.public_dir = c.source_dir + "/examples/server/public";
  } else if (!public_cli && public_env != nullptr) {
    c.public_dir = public_env;
  }
  if (!header_cli && header_env == nullptr) {
    c.httplib_header = c.source_dir + "/examples/server/httplib.h";
  } else if (!header_cli && header_env != nullptr) {
    c.httplib_header = header_env;
  }
  if (!upload_cli && upload_env == nullptr) {
    c.upload_dir = c.root_dir + "/var/run/uploads";
  } else if (!upload_cli && upload_env != nullptr) {
    c.upload_dir = upload_env;
  }
  if (!gateway_pid_cli && gateway_pid_env == nullptr) {
    c.gateway_pid_file = c.root_dir + "/var/run/whisper-on-demand-gateway.pid";
  } else if (!gateway_pid_cli && gateway_pid_env != nullptr) {
    c.gateway_pid_file = gateway_pid_env;
  }
  if (!pid_cli && ondemand_pid_env == nullptr && backend_pid_env == nullptr) {
    c.pid_file = c.root_dir + "/var/run/whisper-on-demand-backend.state";
  } else if (!pid_cli && ondemand_pid_env == nullptr && backend_pid_env != nullptr) {
    c.pid_file = backend_pid_env;
  } else if (!pid_cli && ondemand_pid_env != nullptr) {
    c.pid_file = ondemand_pid_env;
  }
  if (!log_cli && ondemand_log_env == nullptr && backend_log_env == nullptr) {
    c.backend_log_file = c.root_dir + "/var/log/whisper-server-on-demand.log";
  } else if (!log_cli && ondemand_log_env == nullptr && backend_log_env != nullptr) {
    c.backend_log_file = backend_log_env;
  } else if (!log_cli && ondemand_log_env != nullptr) {
    c.backend_log_file = ondemand_log_env;
  }

  // root_dir is intentionally retained as supplied for LaunchAgent/path
  // identity compatibility.  The concrete paths use the same old
  // realpath-if-available behavior, but now after all derivation is done.
  c.source_dir = canonical_or(c.source_dir);
  c.server_bin = canonical_or(c.server_bin);
  c.model_file = canonical_or(c.model_file);
  c.public_dir = canonical_or(c.public_dir);
  c.httplib_header = canonical_or(c.httplib_header);

  if (!validate_range(c, error)) return false;
  if (!checked_payload_limit(c.max_upload_bytes, &c.max_payload_bytes, error)) {
    return false;
  }
  return true;
}

}  // namespace whisper_gateway
