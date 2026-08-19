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
MODEL_DIR="${WHISPER_INSTALL_ROOT}/models"
MODEL_FILE="${MODEL_DIR}/ggml-${WHISPER_MODEL}.bin"
STATE_DIR="${WHISPER_INSTALL_ROOT}/var/state"
LOG_DIR="${WHISPER_INSTALL_ROOT}/var/log"
RUN_DIR="${WHISPER_INSTALL_ROOT}/var/run"
SERVER_BIN="${BIN_DIR}/whisper-server"
CLI_BIN="${BIN_DIR}/whisper-cli"
SERVER_PID_FILE="${RUN_DIR}/whisper-server.pid"
SERVER_LOG_FILE="${LOG_DIR}/whisper-server.log"

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
  [[ -f "${MODEL_FILE}" ]] || die "模型不存在：${MODEL_FILE}；先运行 03-download-model.sh。"

  local actual_size actual_hash
  actual_size="$(file_size_bytes "${MODEL_FILE}")"
  [[ "${actual_size}" == "${WHISPER_MODEL_SIZE_BYTES}" ]] || \
    die "模型大小不符：实际 ${actual_size}，预期 ${WHISPER_MODEL_SIZE_BYTES}。"

  actual_hash="$(sha256_file "${MODEL_FILE}")"
  [[ "${actual_hash}" == "${WHISPER_MODEL_SHA256}" ]] || \
    die "模型 SHA-256 不符：${actual_hash}"
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

pid_is_our_server() {
  local pid="$1"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  /bin/ps -p "${pid}" -o command= 2>/dev/null | /usr/bin/grep -F -- "${SERVER_BIN}" >/dev/null
}
