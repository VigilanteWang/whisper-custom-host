#!/usr/bin/env bash

# Remove whisper-custom-host runtime state without removing the checkout itself.
# This script intentionally uses only Bash 3.2-compatible features because it is
# intended to run on the macOS system that hosts the service.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DRY_RUN=0
ASSUME_YES=0
OS_NAME="${WHISPER_UNINSTALL_UNAME:-$(uname -s)}"

usage() {
  cat <<'EOF'
用法：
  ./uninstall.sh [--dry-run]
  ./uninstall.sh --yes

说明：
  默认交互式完整卸载本工具创建的服务、运行时、模型、日志、仓库构建物，
  并移除本工具的精确 macOS Application Firewall 规则。
  --dry-run 只展示目标，不停止服务、不调用 sudo、不删除文件。
  --yes      跳过固定确认词，适合已审阅目标清单的自动化执行。

保留：
  当前仓库源码、脚本、文档、.env、根目录 models/ 和其它未列出的 untracked 文件；
  Homebrew、Git/CMake/FFmpeg、SSH/WOL、firewall helper 与远端设置不由本脚本删除。
EOF
}

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

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      printf '错误：未知参数：%s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

(( EUID != 0 )) || die '不要用 root 或 sudo 运行 uninstall.sh；它必须管理当前用户的 launchd 和 HOME。'
[[ "${OS_NAME}" == 'Darwin' ]] || die "只支持 macOS（当前系统：${OS_NAME}）。"

CONFIG_FILE="${WHISPER_CONFIG_FILE:-}"
if [[ -z "${CONFIG_FILE}" ]]; then
  if [[ -f "${PROJECT_ROOT}/.env" ]]; then
    CONFIG_FILE="${PROJECT_ROOT}/.env"
  else
    CONFIG_FILE="${PROJECT_ROOT}/.env.example"
  fi
fi
[[ -f "${CONFIG_FILE}" ]] || die "找不到配置文件：${CONFIG_FILE}"
# 与现有脚本保持一致：.env 是用户明确提供的 Bash 配置文件。
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

WHISPER_INSTALL_ROOT="${WHISPER_INSTALL_ROOT:-${PROJECT_ROOT}}"
WHISPER_MODEL="${WHISPER_MODEL:-large-v3-turbo}"
WHISPER_COMMIT="${WHISPER_COMMIT:-306c88f4d1286aec1bf96e544632897886af5501}"
WHISPER_APP_SUPPORT_ROOT="${WHISPER_APP_SUPPORT_ROOT:-${HOME}/Library/Application Support/whisper-custom-host}"
WHISPER_HOST="${WHISPER_HOST:-0.0.0.0}"
WHISPER_PORT="${WHISPER_PORT:-8080}"
WHISPER_GATEWAY_PORT="${WHISPER_GATEWAY_PORT:-8080}"
WHISPER_BACKEND_PORT="${WHISPER_BACKEND_PORT:-18080}"
WHISPER_INFERENCE_PATH="${WHISPER_INFERENCE_PATH:-/v1/audio/transcriptions}"
WHISPER_SHUTDOWN_TIMEOUT_SECONDS="${WHISPER_SHUTDOWN_TIMEOUT_SECONDS:-15}"

LAUNCHD_LABEL='com.local.whisper-on-demand-gateway'
LAUNCHD_MANAGED_BY='whisper-custom-host/08-on-demand-service.sh'
LAUNCHD_PLIST_FILE="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
LAUNCHD_LOG_DIR="${HOME}/Library/Logs/whisper-custom-host"
LAUNCHD_DOMAIN="gui/$(id -u)"

BUILD_DIR="${WHISPER_INSTALL_ROOT}/build"
SOURCE_DIR="${WHISPER_INSTALL_ROOT}/third_party/whisper.cpp"
VAR_DIR="${WHISPER_INSTALL_ROOT}/var"
ROOT_MODELS_DIR="${WHISPER_INSTALL_ROOT}/models"
DIRECT_BIN="${WHISPER_INSTALL_ROOT}/build/whisper.cpp/bin/whisper-server"
DIRECT_PID_FILE="${WHISPER_INSTALL_ROOT}/var/run/whisper-server.pid"
APP_MODEL_FILE="${WHISPER_APP_SUPPORT_ROOT}/runtime/models/ggml-${WHISPER_MODEL}.bin"
LEGACY_MODEL_FILE="${ROOT_MODELS_DIR}/ggml-${WHISPER_MODEL}.bin"
GATEWAY_BIN="${WHISPER_APP_SUPPORT_ROOT}/bin/whisper-on-demand-gateway"
BACKEND_BIN="${WHISPER_APP_SUPPORT_ROOT}/bin/whisper-server"
GATEWAY_PID_FILE="${WHISPER_APP_SUPPORT_ROOT}/runtime/run/whisper-on-demand-gateway.pid"
BACKEND_PID_FILE="${WHISPER_APP_SUPPORT_ROOT}/runtime/run/whisper-on-demand-backend.pid"

# Test shims are accepted only under the fixture-only test marker. Production
# always uses the absolute macOS tools, so a PATH/env change cannot redirect a
# destructive call on the live service.
if [[ -n "${WHISPER_UNINSTALL_TEST_MODE:-}" ]]; then
  LAUNCHCTL="${WHISPER_UNINSTALL_LAUNCHCTL:-/bin/launchctl}"
  PLUTIL="${WHISPER_UNINSTALL_PLUTIL:-/usr/bin/plutil}"
  LSOF="${WHISPER_UNINSTALL_LSOF:-/usr/sbin/lsof}"
  FIREWALL_TOOL="${WHISPER_UNINSTALL_FIREWALL_TOOL:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
  SUDO_BIN="${WHISPER_UNINSTALL_SUDO:-/usr/bin/sudo}"
else
  LAUNCHCTL=/bin/launchctl
  PLUTIL=/usr/bin/plutil
  LSOF=/usr/sbin/lsof
  PS_BIN=/bin/ps
  FIREWALL_TOOL=/usr/libexec/ApplicationFirewall/socketfilterfw
  SUDO_BIN=/usr/bin/sudo
fi
if [[ -n "${WHISPER_UNINSTALL_TEST_MODE:-}" ]]; then
  PS_BIN="${WHISPER_UNINSTALL_PS:-/bin/ps}"
fi
FIREWALL_RULES=()

is_existing_path() {
  [[ -e "$1" || -L "$1" ]]
}

is_absolute_path() {
  [[ "$1" == /* ]]
}

path_is_symlink() {
  [[ -L "$1" ]]
}

assert_no_symlink_components() {
  local path="$1" label="$2" current=/ component
  local old_ifs="${IFS}"
  IFS='/'
  read -r -a components <<< "${path#/}"
  IFS="${old_ifs}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ ! -L "${current}" ]] || die "拒绝操作含符号链接祖先的 ${label}：${path}"
  done
}

assert_no_dot_components() {
  local path="$1" label="$2" component
  local old_ifs="${IFS}"
  IFS='/'
  read -r -a components <<< "${path#/}"
  IFS="${old_ifs}"
  for component in "${components[@]}"; do
    [[ "${component}" != . && "${component}" != .. ]] ||
      die "拒绝包含 . 或 .. 组件的 ${label}：${path}"
  done
}

assert_basic_path() {
  local path="$1" label="$2"
  [[ -n "${path}" ]] || die "${label} 路径为空。"
  is_absolute_path "${path}" || die "${label} 必须是绝对路径：${path}"
  assert_no_dot_components "${path}" "${label}"
  [[ "${path}" != '/' && "${path}" != "${HOME}" ]] || die "拒绝把 ${label} 指向系统/用户根目录：${path}"
  if [[ "${label}" != WHISPER_INSTALL_ROOT && "${path}" == "${PROJECT_ROOT}" ]]; then
    die "拒绝把 ${label} 指向项目源码根目录。"
  fi
  path_is_symlink "${path}" && die "拒绝删除符号链接 ${label}：${path}"
  assert_no_symlink_components "${path}" "${label}"
  return 0
}

assert_configuration() {
  assert_basic_path "${WHISPER_INSTALL_ROOT}" WHISPER_INSTALL_ROOT
  assert_basic_path "${WHISPER_APP_SUPPORT_ROOT}" WHISPER_APP_SUPPORT_ROOT
  [[ -f "${PROJECT_ROOT}/install.sh" && -d "${PROJECT_ROOT}/scripts" ]] ||
    die "当前脚本不在预期项目 checkout 中：${PROJECT_ROOT}"
  if [[ -z "${WHISPER_UNINSTALL_TEST_MODE:-}" ]]; then
    [[ "$(cd "${WHISPER_INSTALL_ROOT}" 2>/dev/null && pwd -P)" == "${PROJECT_ROOT}" ]] ||
      die "生产卸载只能针对当前 checkout：${WHISPER_INSTALL_ROOT}"
  fi
  [[ "$(basename "${WHISPER_APP_SUPPORT_ROOT}")" == whisper-custom-host ]] ||
    die "WHISPER_APP_SUPPORT_ROOT 的最后一级必须是 whisper-custom-host：${WHISPER_APP_SUPPORT_ROOT}"
  if is_existing_path "${WHISPER_APP_SUPPORT_ROOT}"; then
    [[ "$(stat -f '%u' "${WHISPER_APP_SUPPORT_ROOT}" 2>/dev/null || true)" == "$(id -u)" ]] ||
      die "Application Support 根目录不属于当前用户，拒绝继续：${WHISPER_APP_SUPPORT_ROOT}"
  fi
  [[ "${WHISPER_MODEL}" != */* && "${WHISPER_MODEL}" != *$'\n'* ]] ||
    die "WHISPER_MODEL 含有非法路径字符：${WHISPER_MODEL}"
  [[ "${WHISPER_COMMIT}" =~ ^[0-9a-fA-F]{40}$ ]] ||
    die "WHISPER_COMMIT 不是 40 位十六进制 commit：${WHISPER_COMMIT}"
  [[ "${WHISPER_PORT}" =~ ^[0-9]+$ && "${WHISPER_GATEWAY_PORT}" =~ ^[0-9]+$ &&
     "${WHISPER_BACKEND_PORT}" =~ ^[0-9]+$ ]] ||
    die '服务端口必须是十进制整数。'
  [[ "${WHISPER_SHUTDOWN_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] ||
    die 'WHISPER_SHUTDOWN_TIMEOUT_SECONDS 必须是十进制整数。'
  (( WHISPER_SHUTDOWN_TIMEOUT_SECONDS >= 1 && WHISPER_SHUTDOWN_TIMEOUT_SECONDS <= 3600 )) ||
    die 'WHISPER_SHUTDOWN_TIMEOUT_SECONDS 超出范围。'
  [[ ! -L "${WHISPER_INSTALL_ROOT}/build" ]] || die '拒绝删除符号链接 build/。'
  [[ ! -L "${WHISPER_INSTALL_ROOT}/var" ]] || die '拒绝删除符号链接 var/。'
  [[ ! -L "${WHISPER_INSTALL_ROOT}/third_party" ]] || die '拒绝删除符号链接 third_party/。'
  return 0
}

format_status() {
  local path="$1"
  if is_existing_path "${path}"; then
    printf '  [存在] %s\n' "${path}"
  else
    printf '  [不存在] %s\n' "${path}"
  fi
}

plist_value() {
  local key="$1"
  "${PLUTIL}" -extract "${key}" raw -o - "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true
}

plist_is_ours() {
  [[ -f "${LAUNCHD_PLIST_FILE}" ]] || return 1
  local label managed legacy program owner
  label="$(plist_value Label)"
  managed="$(plist_value "EnvironmentVariables.WHISPER_CUSTOM_HOST_MANAGED_BY")"
  legacy="$(plist_value ManagedBy)"
  program="$(plist_value 'ProgramArguments.0')"
  owner="$(stat -f '%u' "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
  if [[ "${label}" != "${LAUNCHD_LABEL}" ]]; then
    label=''
  fi
  if [[ "${managed}" != "${LAUNCHD_MANAGED_BY}" && "${legacy}" != "${LAUNCHD_MANAGED_BY}" ]]; then
    managed=''
  fi
  if [[ "${program}" != "${GATEWAY_BIN}" &&
        "${program}" != "${WHISPER_INSTALL_ROOT}/build/on-demand/bin/whisper-on-demand-gateway" ]]; then
    program=''
  fi
  if [[ "${owner}" != "$(id -u)" ]]; then
    owner=''
  fi
  [[ -n "${label}" && -n "${managed}" && -n "${program}" && -n "${owner}" ]]
}

launchd_is_loaded() {
  "${LAUNCHCTL}" print "${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}" >/dev/null 2>&1
}

process_command() {
  "${PS_BIN}" -p "$1" -o command= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

process_is_alive() {
  kill -0 "$1" 2>/dev/null
}

command_has_pair() {
  local command="$1" flag="$2" value="$3"
  case " ${command} " in
    *" ${flag} ${value} "*) return 0 ;;
  esac
  return 1
}

command_uses_binary() {
  local command="$1" expected="$2"
  [[ "${command}" == "${expected}" || "${command}" == "${expected} "* ]]
}

pid_is_our_direct() {
  local pid="$1" command
  process_is_alive "${pid}" || return 1
  command="$(process_command "${pid}")"
  command_uses_binary "${command}" "${DIRECT_BIN}" || return 1
  command_has_pair "${command}" --host "${WHISPER_HOST}" || return 1
  command_has_pair "${command}" --port "${WHISPER_PORT}" || return 1
  command_has_pair "${command}" --inference-path "${WHISPER_INFERENCE_PATH}" || return 1
  command_has_pair "${command}" --model "${APP_MODEL_FILE}" ||
    command_has_pair "${command}" --model "${LEGACY_MODEL_FILE}" || return 1
}

pid_is_our_gateway() {
  local pid="$1" command
  process_is_alive "${pid}" || return 1
  command="$(process_command "${pid}")"
  command_uses_binary "${command}" "${GATEWAY_BIN}" ||
    command_uses_binary "${command}" "${WHISPER_INSTALL_ROOT}/build/on-demand/bin/whisper-on-demand-gateway" || return 1
  command_has_pair "${command}" --gateway-port "${WHISPER_GATEWAY_PORT}" || return 1
  command_has_pair "${command}" --backend-port "${WHISPER_BACKEND_PORT}" || return 1
  command_has_pair "${command}" --inference-path "${WHISPER_INFERENCE_PATH}" || return 1
  command_has_pair "${command}" --model "${APP_MODEL_FILE}" ||
    command_has_pair "${command}" --model "${LEGACY_MODEL_FILE}" || return 1
}

pid_is_our_backend() {
  local pid="$1" command
  process_is_alive "${pid}" || return 1
  command="$(process_command "${pid}")"
  command_uses_binary "${command}" "${BACKEND_BIN}" || return 1
  command_has_pair "${command}" --host 127.0.0.1 || return 1
  command_has_pair "${command}" --port "${WHISPER_BACKEND_PORT}" || return 1
  command_has_pair "${command}" --model "${APP_MODEL_FILE}" || return 1
}

pid_from_file() {
  local file="$1" record
  [[ -f "${file}" ]] || return 1
  record="$(<"${file}")"
  if [[ "${record}" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${record}" =~ (pid[[:space:]]*[=:][[:space:]]*|\"pid\"[[:space:]]*:[[:space:]]*)([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

listener_pids() {
  "${LSOF}" -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
}

firewall_rule_path() {
  local line="$1" path
  path="$(printf '%s\n' "${line}" | /usr/bin/sed -E 's/^[[:space:]]*[0-9]+[[:space:]]*:[[:space:]]*//; s/[[:space:]]+$//')"
  [[ "${path}" == /* ]] || return 1
  printf '%s\n' "${path}"
}

add_firewall_rule() {
  local path="$1" existing
  [[ -n "${path}" ]] || return 0
  for existing in "${FIREWALL_RULES[@]-}"; do
    [[ "${existing}" == "${path}" ]] && return 0
  done
  FIREWALL_RULES+=("${path}")
}

preflight_firewall() {
  local list line path base
  [[ -x "${FIREWALL_TOOL}" || -n "${WHISPER_UNINSTALL_TEST_MODE:-}" ]] ||
    die "找不到 macOS Application Firewall 工具：${FIREWALL_TOOL}"
  list="$("${FIREWALL_TOOL}" --listapps 2>/dev/null)" ||
    die '无法读取 Application Firewall 规则；尚未停止服务或删除文件。'
  FIREWALL_RULES=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    path="$(firewall_rule_path "${line}" || true)"
    [[ -n "${path}" ]] || continue
    base="$(basename "${path}")"
    if [[ "${path}" == "${DIRECT_BIN}" ||
          "${path}" == "${WHISPER_INSTALL_ROOT}/build/on-demand/bin/whisper-on-demand-gateway" ||
          "${path}" == "${GATEWAY_BIN}" ]]; then
      add_firewall_rule "${path}"
    elif [[ "${path}" == */whisper-custom-host/* &&
            ( "${base}" == whisper-server || "${base}" == whisper-on-demand-gateway ) ]]; then
      add_firewall_rule "${path}"
    fi
  done <<EOF
${list}
EOF
}

preflight_pid_file() {
  local file="$1" kind pid
  kind="$2"
  [[ -e "${file}" || -L "${file}" ]] || return 0
  path_is_symlink "${file}" && die "PID 文件是符号链接，拒绝操作：${file}"
  pid="$(pid_from_file "${file}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || die "PID 文件无法解析，拒绝继续：${file}"
  if process_is_alive "${pid}"; then
    case "${kind}" in
      direct) pid_is_our_direct "${pid}" || die "PID=${pid} 不是本项目 direct server。" ;;
      gateway) pid_is_our_gateway "${pid}" || die "PID=${pid} 不是本项目 Gateway。" ;;
      backend) pid_is_our_backend "${pid}" || die "PID=${pid} 不是本项目 backend。" ;;
    esac
  fi
}

exact_binary_kind() {
  local command="$1"
  if command_uses_binary "${command}" "${DIRECT_BIN}"; then
    printf 'direct\n'
  elif command_uses_binary "${command}" "${GATEWAY_BIN}" ||
       command_uses_binary "${command}" "${WHISPER_INSTALL_ROOT}/build/on-demand/bin/whisper-on-demand-gateway"; then
    printf 'gateway\n'
  elif command_uses_binary "${command}" "${BACKEND_BIN}"; then
    printf 'backend\n'
  fi
}

scan_exact_processes() {
  local pid command kind direct_pid gateway_managed=0
  while read -r pid command; do
    [[ "${pid}" =~ ^[0-9]+$ && -n "${command}" ]] || continue
    kind="$(exact_binary_kind "${command}")"
    [[ -n "${kind}" ]] || continue
    case "${kind}" in
      direct)
        direct_pid="$(pid_from_file "${DIRECT_PID_FILE}" 2>/dev/null || true)"
        if [[ "${direct_pid}" != "${pid}" ]]; then
          die "发现未由本项目 PID 文件可信托管的 direct 进程 PID=${pid}；拒绝继续。"
        fi
        pid_is_our_direct "${pid}" ||
          die "direct 进程参数不属于本项目 PID=${pid}；拒绝继续。"
        ;;
      gateway|backend)
        gateway_managed=0
        if [[ -f "${LAUNCHD_PLIST_FILE}" ]] && launchd_is_loaded && plist_is_ours; then
          gateway_managed=1
        fi
        (( gateway_managed == 1 )) ||
          die "发现未由本项目 loaded LaunchAgent 托管的 ${kind} 进程 PID=${pid}；拒绝继续。"
        if [[ "${kind}" == gateway ]]; then
          pid_is_our_gateway "${pid}" || die "Gateway 进程参数不属于本项目 PID=${pid}；拒绝继续。"
        else
          pid_is_our_backend "${pid}" || die "backend 进程参数不属于本项目 PID=${pid}；拒绝继续。"
        fi
        ;;
    esac
  done <<EOF
$("${PS_BIN}" -axo pid=,command= 2>/dev/null || true)
EOF
}

assert_no_exact_processes() {
  local pid command kind
  while read -r pid command; do
    [[ "${pid}" =~ ^[0-9]+$ && -n "${command}" ]] || continue
    kind="$(exact_binary_kind "${command}")"
    [[ -n "${kind}" ]] || continue
    die "服务停止后仍有本项目 ${kind} 精确二进制进程 PID=${pid}：${command}；拒绝删除运行时。"
  done <<EOF
$("${PS_BIN}" -axo pid=,command= 2>/dev/null || true)
EOF
}

post_stop_verify() {
  local port pid
  assert_no_exact_processes
  for port in "${WHISPER_PORT}" "${WHISPER_GATEWAY_PORT}" "${WHISPER_BACKEND_PORT}"; do
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      die "服务停止后端口 ${port} 仍被 PID=${pid} 占用；拒绝删除运行时。"
    done <<EOF
$(listener_pids "${port}")
EOF
  done
}

preflight_listeners() {
  local port pid
  scan_exact_processes
  for port in "${WHISPER_PORT}" "${WHISPER_GATEWAY_PORT}" "${WHISPER_BACKEND_PORT}"; do
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      if pid_is_our_direct "${pid}" || pid_is_our_gateway "${pid}" || pid_is_our_backend "${pid}"; then
        continue
      fi
      die "端口 ${port} 被未知进程 PID=${pid} 占用；尚未停止服务或删除文件。"
    done <<EOF
$(listener_pids "${port}")
EOF
  done
}

preflight_source() {
  if ! is_existing_path "${SOURCE_DIR}"; then
    return 0
  fi
  [[ -d "${SOURCE_DIR}/.git" && ! -L "${SOURCE_DIR}" ]] ||
    die "third_party/whisper.cpp 不是 Git 目录；为保护文件，拒绝继续。"
  command -v git >/dev/null 2>&1 || die '缺少 git，无法验证 third_party/whisper.cpp；拒绝继续。'
  [[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD 2>/dev/null || true)" == "${WHISPER_COMMIT}" ]] ||
    die "third_party/whisper.cpp commit 不是 pinned ${WHISPER_COMMIT}；拒绝继续。"
  [[ -z "$(git -C "${SOURCE_DIR}" status --porcelain --untracked-files=all 2>/dev/null)" ]] ||
    die 'third_party/whisper.cpp 存在 tracked、cached 或 untracked 改动；拒绝继续。'
}

preflight_all() {
  assert_configuration
  assert_basic_path "${BUILD_DIR}" '仓库 build/'
  assert_basic_path "${VAR_DIR}" '仓库 var/'
  assert_basic_path "${SOURCE_DIR}" 'third_party/whisper.cpp'
  assert_basic_path "${LAUNCHD_LOG_DIR}" 'LaunchAgent 日志'
  assert_no_symlink_components "${LAUNCHD_PLIST_FILE}" 'LaunchAgent plist'
  preflight_source
  preflight_firewall
  preflight_pid_file "${DIRECT_PID_FILE}" direct
  preflight_pid_file "${GATEWAY_PID_FILE}" gateway
  preflight_pid_file "${BACKEND_PID_FILE}" backend
  preflight_listeners
  if [[ -f "${LAUNCHD_PLIST_FILE}" ]]; then
    path_is_symlink "${LAUNCHD_PLIST_FILE}" && die 'LaunchAgent plist 是符号链接，拒绝继续。'
    plist_is_ours || die "同名 LaunchAgent 不属于本工具；拒绝继续：${LAUNCHD_PLIST_FILE}"
  elif launchd_is_loaded; then
    die 'LaunchAgent 已加载但 plist 不存在；拒绝操作未知服务。'
  fi
}

authorize_firewall() {
  if (( ${#FIREWALL_RULES[@]} > 0 )); then
    "${SUDO_BIN}" -v || die 'sudo 预授权失败；尚未停止服务或删除文件。'
  fi
}

stop_owned_pid() {
  local pid="$1" kind="$2" command
  case "${kind}" in
    direct) pid_is_our_direct "${pid}" || die "PID ${pid} 不是本项目 direct server；拒绝 kill。" ;;
    gateway) pid_is_our_gateway "${pid}" || die "PID ${pid} 不是本项目 Gateway；拒绝 kill。" ;;
    backend) pid_is_our_backend "${pid}" || die "PID ${pid} 不是本项目 backend；拒绝 kill。" ;;
    *) die "内部错误：未知进程类型 ${kind}" ;;
  esac
  command="$(process_command "${pid}")"
  log "停止本项目 ${kind}：PID=${pid} ${command}"
  if (( DRY_RUN == 1 )); then
    return 0
  fi
  kill -TERM "${pid}" 2>/dev/null || true
  local deadline=$((SECONDS + WHISPER_SHUTDOWN_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    process_is_alive "${pid}" || return 0
    sleep 0.5
  done
  die "${kind} PID=${pid} 未在安全等待窗口退出；未删除运行时文件。"
}

stop_pid_file() {
  local file="$1" kind="$2" pid
  [[ -e "${file}" || -L "${file}" ]] || return 0
  path_is_symlink "${file}" && die "PID 文件是符号链接，拒绝删除：${file}"
  pid="$(pid_from_file "${file}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || die "PID 文件无法解析，拒绝删除：${file}"
  if process_is_alive "${pid}"; then
    stop_owned_pid "${pid}" "${kind}"
  else
    log "移除失效 PID 文件：${file}"
  fi
  (( DRY_RUN == 1 )) || rm -f -- "${file}"
}

stop_listeners_for_port() {
  local port="$1" pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    if pid_is_our_gateway "${pid}"; then
      stop_owned_pid "${pid}" gateway
    elif pid_is_our_backend "${pid}"; then
      stop_owned_pid "${pid}" backend
    elif pid_is_our_direct "${pid}"; then
      stop_owned_pid "${pid}" direct
    else
      die "端口 ${port} 被未知进程 PID=${pid} 占用；拒绝 kill/删除。"
    fi
  done <<EOF
$(listener_pids "${port}")
EOF
}

remove_tree() {
  local path="$1" label="$2"
  if ! is_existing_path "${path}"; then
    printf '  [跳过] %s 不存在：%s\n' "${label}" "${path}"
    return 0
  fi
  assert_basic_path "${path}" "${label}"
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] 删除 %s：%s\n' "${label}" "${path}"
  else
    rm -rf -- "${path}"
    log "已删除 ${label}：${path}"
  fi
}

source_is_clean_pinned() {
  [[ -d "${SOURCE_DIR}/.git" && ! -L "${SOURCE_DIR}" ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  [[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD 2>/dev/null || true)" == "${WHISPER_COMMIT}" ]] || return 1
  git -C "${SOURCE_DIR}" diff --quiet >/dev/null 2>&1 || return 1
  git -C "${SOURCE_DIR}" diff --cached --quiet >/dev/null 2>&1 || return 1
  [[ -z "$(git -C "${SOURCE_DIR}" status --porcelain --untracked-files=all 2>/dev/null)" ]] || return 1
}

remove_source_if_owned() {
  if ! is_existing_path "${SOURCE_DIR}"; then
    printf '  [跳过] pinned third_party/whisper.cpp 不存在：%s\n' "${SOURCE_DIR}"
    return 0
  fi
  if source_is_clean_pinned; then
    remove_tree "${SOURCE_DIR}" '干净 pinned third_party/whisper.cpp'
  else
    warn "third_party/whisper.cpp 不是干净的 WHISPER_COMMIT=${WHISPER_COMMIT}，保留：${SOURCE_DIR}"
  fi
}

firewall_has_path() {
  local expected="$1" line path
  while IFS= read -r line; do
    path="$(firewall_rule_path "${line}" || true)"
    [[ "${path}" == "${expected}" ]] && return 0
  done <<EOF
$("${FIREWALL_TOOL}" --listapps 2>/dev/null || true)
EOF
  return 1
}

remove_firewall_rule() {
  local path="$1"
  if ! firewall_has_path "${path}"; then
    printf '  [跳过] 未发现 firewall 规则：%s\n' "${path}"
    return 0
  fi
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] 移除精确 firewall 规则：%s\n' "${path}"
    return 0
  fi
  [[ -x "${FIREWALL_TOOL}" || -n "${WHISPER_UNINSTALL_TEST_MODE:-}" ]] ||
    die "找不到 macOS Application Firewall 工具：${FIREWALL_TOOL}"
  "${SUDO_BIN}" "${FIREWALL_TOOL}" --remove "${path}" ||
    die "移除 firewall 规则失败：${path}"
  if firewall_has_path "${path}"; then
    die "移除后仍发现 firewall 规则：${path}"
  fi
  log "已移除精确 firewall 规则：${path}"
}

print_plan() {
  printf '\n将清理以下本项目状态（仓库源码本身不会删除）：\n'
  format_status "${LAUNCHD_PLIST_FILE}"
  format_status "${LAUNCHD_LOG_DIR}"
  format_status "${WHISPER_APP_SUPPORT_ROOT}"
  format_status "${BUILD_DIR}"
  format_status "${VAR_DIR}"
  format_status "${SOURCE_DIR}"
  printf '  [保留] %s\n' "${CONFIG_FILE}"
  printf '  [保留] %s\n' "${ROOT_MODELS_DIR}"
  printf '  [保留] Homebrew、SSH/WOL、%s 和远端设置\n' \
    "${WHISPER_FIREWALL_HELPER:-/usr/local/sbin/whisper-host-admin}"
  local firewall_rule
  for firewall_rule in "${FIREWALL_RULES[@]-}"; do
    [[ -n "${firewall_rule}" ]] || continue
    printf '  [清理] 精确 firewall：%s\n' "${firewall_rule}"
  done
  if launchd_is_loaded; then
    printf '  [状态] LaunchAgent 已加载：%s/%s\n' "${LAUNCHD_DOMAIN}" "${LAUNCHD_LABEL}"
  else
    printf '  [状态] LaunchAgent 未加载：%s/%s\n' "${LAUNCHD_DOMAIN}" "${LAUNCHD_LABEL}"
  fi
}

confirm() {
  if (( ASSUME_YES == 1 )); then
    return 0
  fi
  [[ -t 0 && -t 1 ]] || die '非交互环境必须显式使用 --yes；先用 --dry-run 审阅目标。'
  printf '\n此操作不可逆。请输入 UNINSTALL whisper-custom-host 继续： '
  local answer
  IFS= read -r answer || die '未读取到确认词，已取消。'
  [[ "${answer}" == 'UNINSTALL whisper-custom-host' ]] || die '确认词不匹配，已取消。'
}

direct_service_is_running() {
  local pid
  if [[ -f "${DIRECT_PID_FILE}" ]]; then
    pid="$(pid_from_file "${DIRECT_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && process_is_alive "${pid}" && pid_is_our_direct "${pid}"; then
      return 0
    fi
  fi
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    pid_is_our_direct "${pid}" && return 0
  done <<EOF
$(listener_pids "${WHISPER_PORT}")
EOF
  return 1
}

gateway_service_is_present() {
  [[ -f "${LAUNCHD_PLIST_FILE}" ]] || launchd_is_loaded
}

stop_services() {
  if direct_service_is_running; then
    if [[ -n "${WHISPER_UNINSTALL_TEST_MODE:-}" ]]; then
      die 'fixture 不支持 direct server 进程；拒绝继续。'
    fi
    /bin/bash "${PROJECT_ROOT}/scripts/05-server.sh" stop ||
      die '05-server.sh stop 失败；未删除运行时。'
  fi
  if gateway_service_is_present; then
    if [[ -n "${WHISPER_UNINSTALL_TEST_MODE:-}" ]]; then
      if launchd_is_loaded; then
        "${LAUNCHCTL}" bootout "${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}" ||
          die 'fixture LaunchAgent bootout 失败。'
      fi
    else
      /bin/bash "${PROJECT_ROOT}/scripts/08-on-demand-service.sh" uninstall ||
        die '08-on-demand-service.sh uninstall 失败；未删除运行时。'
    fi
  fi
  if launchd_is_loaded; then
    die '服务停止后 LaunchAgent 仍处于 loaded，拒绝删除运行时。'
  fi
  post_stop_verify
  return 0
}

remove_plist() {
  [[ -e "${LAUNCHD_PLIST_FILE}" || -L "${LAUNCHD_PLIST_FILE}" ]] || return 0
  path_is_symlink "${LAUNCHD_PLIST_FILE}" && die 'LaunchAgent plist 是符号链接，拒绝删除。'
  plist_is_ours || die "拒绝删除非本工具 plist：${LAUNCHD_PLIST_FILE}"
  if (( DRY_RUN == 1 )); then
    printf '  [dry-run] 删除 LaunchAgent plist：%s\n' "${LAUNCHD_PLIST_FILE}"
  else
    rm -f -- "${LAUNCHD_PLIST_FILE}"
    log "已删除 LaunchAgent plist：${LAUNCHD_PLIST_FILE}"
  fi
}

verify_final() {
  local firewall_rule
  if launchd_is_loaded; then
    die '最终验证失败：LaunchAgent 仍处于 loaded。'
  fi
  [[ ! -e "${LAUNCHD_PLIST_FILE}" && ! -L "${LAUNCHD_PLIST_FILE}" ]] ||
    die "最终验证失败：LaunchAgent plist 仍存在：${LAUNCHD_PLIST_FILE}"
  [[ ! -e "${WHISPER_APP_SUPPORT_ROOT}" && ! -L "${WHISPER_APP_SUPPORT_ROOT}" ]] ||
    die "最终验证失败：Application Support 运行时仍存在：${WHISPER_APP_SUPPORT_ROOT}"
  [[ ! -e "${LAUNCHD_LOG_DIR}" && ! -L "${LAUNCHD_LOG_DIR}" ]] ||
    die "最终验证失败：LaunchAgent 日志仍存在：${LAUNCHD_LOG_DIR}"
  [[ ! -e "${BUILD_DIR}" && ! -L "${BUILD_DIR}" ]] ||
    die "最终验证失败：build/ 仍存在：${BUILD_DIR}"
  [[ ! -e "${VAR_DIR}" && ! -L "${VAR_DIR}" ]] ||
    die "最终验证失败：var/ 仍存在：${VAR_DIR}"
  [[ ! -e "${SOURCE_DIR}" && ! -L "${SOURCE_DIR}" ]] ||
    die "最终验证失败：pinned third_party/whisper.cpp 仍存在：${SOURCE_DIR}"
  post_stop_verify
  for firewall_rule in "${FIREWALL_RULES[@]-}"; do
    [[ -n "${firewall_rule}" ]] || continue
    if firewall_has_path "${firewall_rule}"; then
      die "最终验证失败：firewall 规则仍存在：${firewall_rule}"
    fi
  done
  return 0
}

main() {
  preflight_all
  print_plan
  if (( DRY_RUN == 1 )); then
    exit 0
  fi
  confirm

  authorize_firewall
  stop_services
  local firewall_rule
  for firewall_rule in "${FIREWALL_RULES[@]-}"; do
    [[ -n "${firewall_rule}" ]] || continue
    remove_firewall_rule "${firewall_rule}"
  done
  remove_plist
  remove_tree "${WHISPER_APP_SUPPORT_ROOT}" 'Application Support 运行时和模型'
  remove_tree "${LAUNCHD_LOG_DIR}" 'LaunchAgent 日志'
  remove_tree "${BUILD_DIR}" '仓库 build/'
  remove_tree "${VAR_DIR}" '仓库 var/'
  remove_source_if_owned
  verify_final

  printf '\n卸载完成。保留仓库源码、.env、根 models/、其它 untracked、Homebrew、SSH/WOL 和 helper。\n'
}

main "$@"
