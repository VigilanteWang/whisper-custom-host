#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd -P)"
DEFAULT_CONFIG_FILE="${PROJECT_ROOT}/.env.example"
LOCAL_CONFIG_FILE="${PROJECT_ROOT}/.env"

if [[ -n "${WHISPER_CONFIG_FILE:-}" ]]; then
  CONFIG_FILE="${WHISPER_CONFIG_FILE}"
elif [[ -f "${LOCAL_CONFIG_FILE}" ]]; then
  CONFIG_FILE="${LOCAL_CONFIG_FILE}"
else
  CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  printf '错误：找不到配置文件：%s\n' "${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=../../.env.example
source "${CONFIG_FILE}"

: "${WHISPER_INSTALL_ROOT:?配置缺少 WHISPER_INSTALL_ROOT}"
: "${WHISPER_TAG:?配置缺少 WHISPER_TAG}"
: "${WHISPER_COMMIT:?配置缺少 WHISPER_COMMIT}"
: "${WHISPER_MODEL:?配置缺少 WHISPER_MODEL}"
: "${WHISPER_MODEL_SHA256:?配置缺少 WHISPER_MODEL_SHA256}"
: "${WHISPER_MODEL_SIZE_BYTES:?配置缺少 WHISPER_MODEL_SIZE_BYTES}"
: "${WHISPER_HOST:?配置缺少 WHISPER_HOST}"
: "${WHISPER_PORT:?配置缺少 WHISPER_PORT}"
: "${WHISPER_INFERENCE_PATH:?配置缺少 WHISPER_INFERENCE_PATH}"
: "${WHISPER_LANGUAGE:?配置缺少 WHISPER_LANGUAGE}"
: "${WHISPER_THREADS:?配置缺少 WHISPER_THREADS}"

# 按需网关配置。旧版 .env 只包含 direct 模式的 WHISPER_HOST/WHISPER_PORT
# 时，按需模式使用独立的计划默认端口，不改变 direct 的旧行为，也不把
# 默认值写回 .env。网络拓扑不是用户配置：网关必须服务 LAN，后端必须留在
# loopback，避免把 whisper-server 管理接口暴露给局域网。
ON_DEMAND_GATEWAY_HOST="0.0.0.0"
ON_DEMAND_BACKEND_HOST="127.0.0.1"
WHISPER_GATEWAY_PORT="${WHISPER_GATEWAY_PORT:-8080}"
WHISPER_BACKEND_PORT="${WHISPER_BACKEND_PORT:-18080}"
WHISPER_IDLE_TIMEOUT_SECONDS="${WHISPER_IDLE_TIMEOUT_SECONDS:-300}"
WHISPER_STARTUP_TIMEOUT_SECONDS="${WHISPER_STARTUP_TIMEOUT_SECONDS:-180}"
WHISPER_SHUTDOWN_TIMEOUT_SECONDS="${WHISPER_SHUTDOWN_TIMEOUT_SECONDS:-15}"
WHISPER_REQUEST_TIMEOUT_SECONDS="${WHISPER_REQUEST_TIMEOUT_SECONDS:-900}"
WHISPER_MAX_PENDING_REQUESTS="${WHISPER_MAX_PENDING_REQUESTS:-4}"
WHISPER_MAX_UPLOAD_BYTES="${WHISPER_MAX_UPLOAD_BYTES:-268435456}"
WHISPER_START_FAILURE_BACKOFF_SECONDS="${WHISPER_START_FAILURE_BACKOFF_SECONDS:-10}"
WHISPER_APP_SUPPORT_ROOT="${WHISPER_APP_SUPPORT_ROOT:-${HOME}/Library/Application Support/whisper-custom-host}"

# 这些值用于 LAN 地址展示、防火墙 helper 和未来 launchd 配置；对旧版 .env
# 保持运行时默认值，避免用户必须手工补齐新配置项。
WHISPER_LAN_HOST="${WHISPER_LAN_HOST:-$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || /bin/hostname -s)}"
WHISPER_SERVICE_USER="${WHISPER_SERVICE_USER:-$(/usr/bin/id -un)}"
WHISPER_FIREWALL_HELPER="${WHISPER_FIREWALL_HELPER:-/usr/local/sbin/whisper-host-admin}"
WHISPER_SSH_ALIAS="${WHISPER_SSH_ALIAS:-macmini-m4}"
WHISPER_SSH_HOST="${WHISPER_SSH_HOST:-${WHISPER_LAN_HOST}}"
WHISPER_SSH_USER="${WHISPER_SSH_USER:-${WHISPER_SERVICE_USER}}"
WHISPER_SSH_PORT="${WHISPER_SSH_PORT:-22}"
WHISPER_SSH_IDENTITY_FILE="${WHISPER_SSH_IDENTITY_FILE:-${HOME}/.ssh/macmini-m4-ed25519}"
WHISPER_SSH_CONFIG_FILE="${WHISPER_SSH_CONFIG_FILE:-${HOME}/.ssh/config}"
WHISPER_SSH_CONFIG_FRAGMENT="${WHISPER_SSH_CONFIG_FRAGMENT:-${HOME}/.ssh/config.d/whisper-custom-host.conf}"
WHISPER_WOL_PROXY_FILE="${WHISPER_WOL_PROXY_FILE:-${HOME}/.ssh/macmini-m4-wake-proxy}"
WHISPER_WOL_BROADCAST="${WHISPER_WOL_BROADCAST:-}"
WHISPER_WOL_MAC="${WHISPER_WOL_MAC:-}"
WHISPER_SSH_CONNECT_TIMEOUT="${WHISPER_SSH_CONNECT_TIMEOUT:-40}"
WHISPER_SSH_ALIVE_INTERVAL="${WHISPER_SSH_ALIVE_INTERVAL:-30}"
WHISPER_SSH_ALIVE_COUNT_MAX="${WHISPER_SSH_ALIVE_COUNT_MAX:-3}"
WHISPER_WOL_WAIT_SECONDS="${WHISPER_WOL_WAIT_SECONDS:-30}"
WHISPER_WOL_SEND_COUNT="${WHISPER_WOL_SEND_COUNT:-5}"

SOURCE_DIR="${WHISPER_INSTALL_ROOT}/third_party/whisper.cpp"
BUILD_DIR="${WHISPER_INSTALL_ROOT}/build/whisper.cpp"
BIN_DIR="${BUILD_DIR}/bin"
GATEWAY_SERVICE_DIR="${WHISPER_APP_SUPPORT_ROOT}"
GATEWAY_RUNTIME_DIR="${GATEWAY_SERVICE_DIR}/runtime"
MODEL_DIR="${GATEWAY_RUNTIME_DIR}/models"
MODEL_FILE="${MODEL_DIR}/ggml-${WHISPER_MODEL}.bin"
MODEL_STATE_FILE="${MODEL_DIR}/model.txt"
LEGACY_MODEL_FILE="${WHISPER_INSTALL_ROOT}/models/ggml-${WHISPER_MODEL}.bin"
STATE_DIR="${WHISPER_INSTALL_ROOT}/var/state"
LOG_DIR="${WHISPER_INSTALL_ROOT}/var/log"
RUN_DIR="${WHISPER_INSTALL_ROOT}/var/run"
SERVER_BIN="${BIN_DIR}/whisper-server"
CLI_BIN="${BIN_DIR}/whisper-cli"
SERVER_PID_FILE="${RUN_DIR}/whisper-server.pid"
SERVER_LOG_FILE="${LOG_DIR}/whisper-server.log"

# 仓库保存可审计构建产物；LaunchAgent 的最小运行时副本放在用户
# Application Support，避免后台进程触发 ~/Documents 的 TCC 阻塞。
ON_DEMAND_BUILD_DIR="${WHISPER_INSTALL_ROOT}/build/on-demand"
ON_DEMAND_BIN_DIR="${ON_DEMAND_BUILD_DIR}/bin"
ON_DEMAND_BUILD_GATEWAY_BIN="${ON_DEMAND_BIN_DIR}/whisper-on-demand-gateway"
# LaunchAgents can stall in dyld before main() when a newly replaced Mach-O is
# opened from macOS-protected ~/Documents.  Keep the audited build artifact in
# the checkout, but execute a verified copy from the user's Application Support.
GATEWAY_SERVICE_BIN_DIR="${GATEWAY_SERVICE_DIR}/bin"
GATEWAY_RUNTIME_SOURCE_DIR="${GATEWAY_RUNTIME_DIR}/whisper.cpp"
GATEWAY_RUNTIME_SERVER_BIN="${GATEWAY_SERVICE_BIN_DIR}/whisper-server"
GATEWAY_RUNTIME_MODEL_FILE="${MODEL_FILE}"
GATEWAY_RUNTIME_HTTPLIB_HEADER="${GATEWAY_RUNTIME_SOURCE_DIR}/examples/server/httplib.h"
GATEWAY_RUNTIME_RUN_DIR="${GATEWAY_RUNTIME_DIR}/run"
GATEWAY_RUNTIME_LOG_DIR="${GATEWAY_RUNTIME_DIR}/log"
GATEWAY_BIN="${GATEWAY_SERVICE_BIN_DIR}/whisper-on-demand-gateway"
GATEWAY_PID_FILE="${GATEWAY_RUNTIME_RUN_DIR}/whisper-on-demand-gateway.pid"
BACKEND_PID_FILE="${GATEWAY_RUNTIME_RUN_DIR}/whisper-on-demand-backend.pid"
UPLOAD_DIR="${GATEWAY_RUNTIME_RUN_DIR}/uploads"
GATEWAY_LOG_FILE="${GATEWAY_RUNTIME_LOG_DIR}/whisper-on-demand-gateway.log"
BACKEND_LOG_FILE="${GATEWAY_RUNTIME_LOG_DIR}/whisper-on-demand-backend.log"
# 语义化别名，供构建/测试脚本引用；实际路径只有上面这组单一来源。
ON_DEMAND_GATEWAY_BIN="${ON_DEMAND_BUILD_GATEWAY_BIN}"
ON_DEMAND_GATEWAY_PID_FILE="${GATEWAY_PID_FILE}"
ON_DEMAND_BACKEND_PID_FILE="${BACKEND_PID_FILE}"
ON_DEMAND_UPLOAD_DIR="${UPLOAD_DIR}"
ON_DEMAND_GATEWAY_LOG_FILE="${GATEWAY_LOG_FILE}"
ON_DEMAND_BACKEND_LOG_FILE="${BACKEND_LOG_FILE}"
LAUNCHD_LABEL="com.local.whisper-on-demand-gateway"
LAUNCHD_MANAGED_BY="whisper-custom-host/08-on-demand-service.sh"
LAUNCHD_MANAGED_ENV_KEY="WHISPER_CUSTOM_HOST_MANAGED_BY"
LAUNCHD_DIR="${WHISPER_INSTALL_ROOT}/launchd"
LAUNCHD_PLIST_FILE="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
# LaunchAgent 自身日志也放在用户 Library Logs，避免后台 xpcproxy 访问
# ~/Documents 下的 Standard*Path。
LAUNCHD_LOG_DIR="${HOME}/Library/Logs/whisper-custom-host"
LAUNCHD_GATEWAY_STDOUT_FILE="${LAUNCHD_LOG_DIR}/whisper-on-demand-gateway.stdout.log"
LAUNCHD_GATEWAY_STDERR_FILE="${LAUNCHD_LOG_DIR}/whisper-on-demand-gateway.stderr.log"

if [[ -x /opt/homebrew/bin/brew ]]; then
  export PATH="/opt/homebrew/bin:${PATH}"
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '警告：%s\n' "$*" >&2
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

is_decimal_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_integer_range() {
  local name="$1" value="$2" minimum="$3" maximum="$4" numeric
  is_decimal_integer "${value}" || die "${name} 必须是十进制非负整数：${value}"
  numeric=$((10#${value}))
  (( numeric >= minimum && numeric <= maximum )) ||
    die "${name} 超出范围：${value}（允许 ${minimum}-${maximum}）。"
}

validate_port_value() {
  validate_integer_range "$1" "$2" 1 65535
}

validate_host_value() {
  local name="$1" host="$2"
  [[ -n "${host}" ]] || die "${name} 不能为空。"
  [[ "${host}" != *[[:space:]/\\]* ]] || die "${name} 含有非法空白或路径字符：${host}"

  # 允许常见 IPv4 地址。逐段校验可以拒绝 999.1.1.1 等会被系统解析器
  # 以非预期方式解释的值。
  if [[ "${host}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    local old_ifs="${IFS}" octet
    IFS='.' read -r -a octets <<< "${host}"
    IFS="${old_ifs}"
    for octet in "${octets[@]}"; do
      validate_integer_range "${name} IPv4 段" "${octet}" 0 255
    done
    return 0
  fi

  # 不接受 IPv6 或带端口的 host；网关协议和 launchd 参数均使用独立的
  # host/port 字段，避免把 [::1]:8080 当作一个 host 传下去。
  [[ "${#host}" -le 253 && "${host}" != .* && "${host}" != *..* ]] ||
    die "${name} 不是合法主机名或 IPv4 地址：${host}"
  local label
  local old_ifs="${IFS}"
  IFS='.' read -r -a host_labels <<< "${host}"
  IFS="${old_ifs}"
  for label in "${host_labels[@]}"; do
    [[ "${#label}" -le 63 && "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      die "${name} 不是合法主机名或 IPv4 地址：${host}"
  done
  return 0
}

validate_configuration() {
  [[ "${WHISPER_INSTALL_ROOT}" == /* ]] ||
    die "WHISPER_INSTALL_ROOT 必须是绝对路径：${WHISPER_INSTALL_ROOT}"
  [[ "${WHISPER_APP_SUPPORT_ROOT}" == /* ]] ||
    die "WHISPER_APP_SUPPORT_ROOT 必须是绝对路径：${WHISPER_APP_SUPPORT_ROOT}"
  validate_host_value WHISPER_HOST "${WHISPER_HOST}"
  validate_port_value WHISPER_PORT "${WHISPER_PORT}"
  validate_port_value WHISPER_GATEWAY_PORT "${WHISPER_GATEWAY_PORT}"
  validate_port_value WHISPER_BACKEND_PORT "${WHISPER_BACKEND_PORT}"
  [[ "${WHISPER_GATEWAY_PORT}" != "${WHISPER_BACKEND_PORT}" ]] ||
    die "WHISPER_GATEWAY_PORT 与 WHISPER_BACKEND_PORT 不能相同。"

  validate_integer_range WHISPER_THREADS "${WHISPER_THREADS}" 1 256
  validate_integer_range WHISPER_MODEL_SIZE_BYTES "${WHISPER_MODEL_SIZE_BYTES}" 1 1099511627776
  validate_integer_range WHISPER_IDLE_TIMEOUT_SECONDS "${WHISPER_IDLE_TIMEOUT_SECONDS}" 1 604800
  validate_integer_range WHISPER_STARTUP_TIMEOUT_SECONDS "${WHISPER_STARTUP_TIMEOUT_SECONDS}" 1 86400
  validate_integer_range WHISPER_SHUTDOWN_TIMEOUT_SECONDS "${WHISPER_SHUTDOWN_TIMEOUT_SECONDS}" 1 3600
  validate_integer_range WHISPER_REQUEST_TIMEOUT_SECONDS "${WHISPER_REQUEST_TIMEOUT_SECONDS}" 1 86400
  validate_integer_range WHISPER_MAX_PENDING_REQUESTS "${WHISPER_MAX_PENDING_REQUESTS}" 1 1024
  validate_integer_range WHISPER_MAX_UPLOAD_BYTES "${WHISPER_MAX_UPLOAD_BYTES}" 1 1099511627776
  validate_integer_range WHISPER_START_FAILURE_BACKOFF_SECONDS "${WHISPER_START_FAILURE_BACKOFF_SECONDS}" 1 86400

  [[ "${WHISPER_COMMIT}" =~ ^[0-9a-fA-F]{40}$ ]] ||
    die "WHISPER_COMMIT 必须是 40 位十六进制 commit：${WHISPER_COMMIT}"
  [[ "${WHISPER_MODEL_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "WHISPER_MODEL_SHA256 必须是 64 位十六进制 SHA-256。"
  [[ "${WHISPER_INFERENCE_PATH}" == /* && "${WHISPER_INFERENCE_PATH}" != *$'\n'* && "${WHISPER_INFERENCE_PATH}" != *[[:space:]]* ]] ||
    die "WHISPER_INFERENCE_PATH 必须是无空白的绝对 HTTP 路径：${WHISPER_INFERENCE_PATH}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

require_regular_user() {
  [[ "${EUID}" -ne 0 ]] || die "不要用 root 或 sudo 运行 whisper server 安装脚本。"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

file_size_bytes() {
  /usr/bin/stat -f '%z' "$1"
}

assert_model_valid() {
  assert_model_file_valid "${MODEL_FILE}"
  [[ ! -L "${MODEL_FILE}" ]] || die "权威模型不能是符号链接：${MODEL_FILE}"

  local owner mode mode_value
  owner="$(/usr/bin/stat -f '%u' "${MODEL_FILE}")"
  [[ "${owner}" == "$(/usr/bin/id -u)" ]] || \
    die "权威模型不属于当前用户：${MODEL_FILE}"
  mode="$(/usr/bin/stat -f '%Lp' "${MODEL_FILE}")"
  mode_value=$((8#${mode}))
  (( (mode_value & 077) == 0 )) || \
    die "权威模型不能允许组或其他用户访问：${MODEL_FILE} mode=${mode}"
}

assert_model_file_valid() {
  local model_path="$1" actual_size actual_hash
  [[ -f "${model_path}" ]] || die "模型不存在：${model_path}；先运行 03-download-model.sh。"

  actual_size="$(file_size_bytes "${model_path}")"
  [[ "${actual_size}" == "${WHISPER_MODEL_SIZE_BYTES}" ]] || \
    die "模型大小不符：${model_path} 实际 ${actual_size}，预期 ${WHISPER_MODEL_SIZE_BYTES}。"

  actual_hash="$(sha256_file "${model_path}")"
  [[ "${actual_hash}" == "${WHISPER_MODEL_SHA256}" ]] || \
    die "模型 SHA-256 不符：${model_path} 实际 ${actual_hash}"
}

# Purge is deliberately implemented as a small, independently testable
# primitive.  It is the only operation in this file that removes anything
# below Application Support.  Callers must perform all service/process
# preflight checks before invoking it.
strip_trailing_slashes() {
  local value="${1:-}"
  while [[ "${value}" != "/" && "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "${value}"
}

path_has_symlink_component() {
  local path="${1:-}" anchor="${2:-/}" remaining component current
  [[ "${path}" == /* ]] || return 1
  anchor="$(strip_trailing_slashes "${anchor}")"
  if [[ "${anchor}" == "/" ]]; then
    current="/"
    remaining="${path#/}"
  else
    case "${path}" in
      "${anchor}/"*) ;;
      *) return 1 ;;
    esac
    current="${anchor}"
    remaining="${path#"${anchor}"/}"
  fi
  while [[ -n "${remaining}" ]]; do
    if [[ "${remaining}" == */* ]]; then
      component="${remaining%%/*}"
      remaining="${remaining#*/}"
    else
      component="${remaining}"
      remaining=""
    fi
    [[ -n "${component}" && "${component}" != "." ]] || continue
    [[ "${component}" != ".." ]] || return 1
    current="${current%/}/${component}"
    [[ -L "${current}" ]] && return 0
  done
  return 1
}

validate_purge_root_safety() {
  local root home project
  root="$(strip_trailing_slashes "${WHISPER_APP_SUPPORT_ROOT:-}")"
  [[ -n "${root}" && "${root}" == /* ]] ||
    die "Purge 根目录必须是非空绝对路径：${WHISPER_APP_SUPPORT_ROOT:-<空>}"
  [[ "${root}" != *$'\n'* && "${root}" != *$'\r'* ]] ||
    die "Purge 根目录不能包含换行：${root}"
  [[ "${root}" != *"/../"* && "${root}" != */.. && \
    "${root}" != *"/./"* && "${root}" != */. ]] ||
    die "Purge 根目录不能包含 . 或 .. 路径组件：${root}"
  [[ "${root}" != "/" ]] || die "拒绝把 / 作为 Purge 根目录。"
  [[ ! -L "${root}" ]] || die "Purge 根目录不能是符号链接：${root}"
  if [[ -e "${root}" && ! -d "${root}" ]]; then
    die "Purge 根目录不是目录：${root}"
  fi
  path_has_symlink_component "${root}" &&
    die "Purge 根目录路径包含符号链接组件：${root}"
  [[ "${root##*/}" == "whisper-custom-host" ]] ||
    die "Purge 根目录 basename 必须是 whisper-custom-host：${root}"

  home="$(strip_trailing_slashes "${HOME:-}")"
  project="$(strip_trailing_slashes "${PROJECT_ROOT:-}")"
  case "${root}" in
    "${home}"|"${home}/Library"|"${home}/Library/Logs"|\
    "${home}/Library/Application Support"|\
    "/Library"|"/System"|"/Applications"|"/Users"|"/private"|\
    "/private/var"|"/tmp"|"/private/tmp"|\
    "${project}")
      die "Purge 根目录过于宽泛或指向项目目录：${root}"
      ;;
  esac
  # Reject only the checkout itself, a path inside it, or a path that is its
  # ancestor.  A normal Application Support sibling must remain allowed when
  # the checkout is under Documents (or directly under HOME).
  case "${root}" in
    "${project}"|"${project}/"*)
      die "Purge 根目录不能位于项目目录或其父目录：${root}"
      ;;
  esac
  case "${project}" in
    "${root}"|"${root}/"*)
      die "Purge 根目录不能是项目目录的父目录：${root}"
      ;;
  esac
}

validate_purge_model() {
  local root model
  validate_purge_root_safety
  [[ "${WHISPER_MODEL}" != *"/"* && "${WHISPER_MODEL}" != *"\\"* && \
    "${WHISPER_MODEL}" != *$'\n'* && "${WHISPER_MODEL}" != *$'\r'* ]] ||
    die "Purge 不接受含路径分隔符或换行的模型名：${WHISPER_MODEL}"
  root="$(strip_trailing_slashes "${WHISPER_APP_SUPPORT_ROOT}")"
  model="$(strip_trailing_slashes "${MODEL_FILE}")"
  case "${model}" in
    "${root}/"*) ;;
    *) die "权威模型路径不在 Purge 根目录内：${MODEL_FILE}" ;;
  esac

  # -L must be checked before -e because a dangling symlink is not -e.  A
  # symlink in an intermediate model path is equally unsafe to preserve.
  if [[ -L "${model}" || -e "${model}" ]]; then
    path_has_symlink_component "${model}" "${root}" &&
      die "权威模型路径包含符号链接：${MODEL_FILE}"
    [[ -f "${model}" && ! -L "${model}" ]] ||
      die "权威模型必须是普通文件：${MODEL_FILE}"
    assert_model_valid
  fi
}

purge_application_support() {
  local root model path model_size model_sha model_owner model_mode model_mtime
  validate_purge_model
  root="$(strip_trailing_slashes "${WHISPER_APP_SUPPORT_ROOT}")"
  model="$(strip_trailing_slashes "${MODEL_FILE}")"

  # Capture attributes before traversal.  The model is never passed to rm;
  # the post-check also detects an unexpected concurrent modification.
  if [[ -f "${model}" && ! -L "${model}" ]]; then
    model_size="$(file_size_bytes "${model}")"
    model_sha="$(sha256_file "${model}")"
    model_owner="$(/usr/bin/stat -f '%u' "${model}")"
    model_mode="$(/usr/bin/stat -f '%Lp' "${model}")"
    model_mtime="$(/usr/bin/stat -f '%m' "${model}")"
  else
    model_size=""
    model_sha=""
    model_owner=""
    model_mode=""
    model_mtime=""
  fi

  if [[ -d "${root}" ]]; then
    # -depth permits removing empty parents after their non-authoritative
    # children.  Ancestors of MODEL_FILE are retained so the exact model path
    # remains usable; every other regular, hidden, temporary, or unknown
    # entry is removed, including symlink entries (without following them).
    while IFS= read -r -d '' path; do
      [[ "${path}" == "${model}" ]] && continue
      case "${model}" in
        "${path}/"*) continue ;;
      esac
      rm -rf -- "${path}" ||
        die "Purge 删除失败：${path}"
    done < <(/usr/bin/find "${root}" -mindepth 1 -depth -print0)
  fi

  if [[ -n "${model_size}" ]]; then
    [[ -f "${model}" && ! -L "${model}" ]] ||
      die "Purge 后权威模型消失或变成符号链接：${model}"
    [[ "$(file_size_bytes "${model}")" == "${model_size}" ]] ||
      die "Purge 后权威模型大小发生变化：${model}"
    [[ "$(sha256_file "${model}")" == "${model_sha}" ]] ||
      die "Purge 后权威模型 SHA-256 发生变化：${model}"
    [[ "$(/usr/bin/stat -f '%u' "${model}")" == "${model_owner}" ]] ||
      die "Purge 后权威模型所有者发生变化：${model}"
    [[ "$(/usr/bin/stat -f '%Lp' "${model}")" == "${model_mode}" ]] ||
      die "Purge 后权威模型权限发生变化：${model}"
    [[ "$(/usr/bin/stat -f '%m' "${model}")" == "${model_mtime}" ]] ||
      die "Purge 后权威模型时间信息发生变化：${model}"
  fi
  log "Application Support purge 完成（权威模型保留）：${root}"
}

health_url() {
  local host="${WHISPER_HOST}"
  [[ "${host}" == "0.0.0.0" ]] && host="127.0.0.1"
  printf 'http://%s:%s/health' "${host}" "${WHISPER_PORT}"
}

server_url() {
  local host="${WHISPER_HOST}"
  [[ "${host}" == "0.0.0.0" ]] && host="127.0.0.1"
  printf 'http://%s:%s%s' "${host}" "${WHISPER_PORT}" "${WHISPER_INFERENCE_PATH}"
}

process_command_line() {
  local pid="$1"
  /bin/ps -p "${pid}" -o command= 2>/dev/null |
    /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

process_executable_matches() {
  local pid="$1" expected="$2" actual command
  actual="$(/bin/ps -p "${pid}" -o comm= 2>/dev/null |
    /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
  [[ "${actual}" == "${expected}" ]] && return 0

  # macOS 的 comm 列在不同系统版本上可能只返回 basename；command 列的
  # 第一个 token 仍必须是我们传入的绝对可执行路径，不能只做 substring 匹配。
  command="$(process_command_line "${pid}" || true)"
  case "${command}" in
    "${expected}"|"${expected} "*) return 0 ;;
  esac
  return 1
}

command_has_exact_argument_pair() {
  local command="$1" flag="$2" value="$3"
  # 参数值来自已校验的 host/port/path；两侧空格是 token 边界，因而不会
  # 把 --port 18080 误认成 --port 180800。解析失败时宁可拒绝接管/停止。
  case " ${command} " in
    *" ${flag} ${value} "*) return 0 ;;
  esac
  return 1
}

pid_is_our_server() {
  local pid="$1" command
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  process_executable_matches "${pid}" "${SERVER_BIN}" || return 1
  command="$(process_command_line "${pid}" || true)"
  command_has_exact_argument_pair "${command}" --host "${WHISPER_HOST}" || return 1
  command_has_exact_argument_pair "${command}" --port "${WHISPER_PORT}" || return 1
  if ! command_has_exact_argument_pair "${command}" --model "${MODEL_FILE}"; then
    command_has_exact_argument_pair "${command}" --model "${LEGACY_MODEL_FILE}" || return 1
  fi
  command_has_exact_argument_pair "${command}" --inference-path "${WHISPER_INFERENCE_PATH}" || return 1
}

pid_is_our_gateway() {
  local pid="$1" command
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if ! process_executable_matches "${pid}" "${GATEWAY_BIN}"; then
    # Upgrade compatibility for a still-running pre-Issue-#2 LaunchAgent.
    process_executable_matches "${pid}" "${ON_DEMAND_BUILD_GATEWAY_BIN}" || return 1
  fi
  command="$(process_command_line "${pid}" || true)"
  command_has_exact_argument_pair "${command}" --gateway-host "${ON_DEMAND_GATEWAY_HOST}" || return 1
  command_has_exact_argument_pair "${command}" --gateway-port "${WHISPER_GATEWAY_PORT}" || return 1
  command_has_exact_argument_pair "${command}" --backend-port "${WHISPER_BACKEND_PORT}" || return 1
  if ! command_has_exact_argument_pair "${command}" --model "${MODEL_FILE}"; then
    # Upgrade compatibility for a pre-migration gateway still using the
    # checkout model path.
    command_has_exact_argument_pair "${command}" --model "${LEGACY_MODEL_FILE}" || return 1
  fi
  command_has_exact_argument_pair "${command}" --inference-path "${WHISPER_INFERENCE_PATH}" || return 1
}

pid_from_file() {
  local pid_file="$1" pid_record
  [[ -f "${pid_file}" ]] || return 1
  pid_record="$(<"${pid_file}")"
  if [[ "${pid_record}" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  # 网关 PID 文件可包含审计元数据（启动时间、二进制、模型和端口）。
  # 兼容 pid=123、"pid":123 等文本/JSON 记录，但不把任意数字当 PID。
  if [[ "${pid_record}" =~ (pid[[:space:]]*[=:][[:space:]]*|\"pid\"[[:space:]]*:[[:space:]]*)([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

listener_pids_for_port() {
  local port="$1"
  /usr/sbin/lsof -nP -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
}

port_is_listening() {
  [[ -n "$(listener_pids_for_port "$1")" ]]
}

on_demand_mode_is_running() {
  if [[ -f "${GATEWAY_PID_FILE}" ]]; then
    local gateway_pid=""
    gateway_pid="$(pid_from_file "${GATEWAY_PID_FILE}" 2>/dev/null || true)"
    [[ -n "${gateway_pid}" ]] && pid_is_our_gateway "${gateway_pid}" && return 0
  fi

  local listener_pid
  while IFS= read -r listener_pid; do
    [[ -n "${listener_pid}" ]] || continue
    pid_is_our_gateway "${listener_pid}" && return 0
  done < <(listener_pids_for_port "${WHISPER_GATEWAY_PORT}")
  return 1
}

direct_mode_is_running() {
  if [[ -f "${SERVER_PID_FILE}" ]]; then
    local server_pid
    server_pid="$(pid_from_file "${SERVER_PID_FILE}" 2>/dev/null || true)"
    [[ -n "${server_pid}" ]] && pid_is_our_server "${server_pid}" && return 0
  fi

  local listener_pid
  while IFS= read -r listener_pid; do
    [[ -n "${listener_pid}" ]] || continue
    pid_is_our_server "${listener_pid}" && return 0
  done < <(listener_pids_for_port "${WHISPER_PORT}")
  return 1
}

gateway_health_url() {
  local host="${ON_DEMAND_GATEWAY_HOST}"
  [[ "${host}" == "0.0.0.0" ]] && host="127.0.0.1"
  printf 'http://%s:%s/health' "${host}" "${WHISPER_GATEWAY_PORT}"
}

gateway_ready_url() {
  local host="${ON_DEMAND_GATEWAY_HOST}"
  [[ "${host}" == "0.0.0.0" ]] && host="127.0.0.1"
  printf 'http://%s:%s/ready' "${host}" "${WHISPER_GATEWAY_PORT}"
}

backend_health_url() {
  printf 'http://%s:%s/health' "${ON_DEMAND_BACKEND_HOST}" "${WHISPER_BACKEND_PORT}"
}

assert_source_commit() {
  [[ -d "${SOURCE_DIR}" ]] || die "whisper.cpp 源码目录不存在：${SOURCE_DIR}"
  require_command git
  local actual_commit
  actual_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD 2>/dev/null || true)"
  [[ "${actual_commit}" == "${WHISPER_COMMIT}" ]] ||
    die "whisper.cpp commit 不符：实际 ${actual_commit:-<无法读取>}，预期 ${WHISPER_COMMIT}。"
}

validate_configuration
