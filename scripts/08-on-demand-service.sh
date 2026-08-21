#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

LAUNCHCTL="/bin/launchctl"
PLUTIL="/usr/bin/plutil"
TAIL="/usr/bin/tail"
MKtemp="/usr/bin/mktemp"
LAUNCHD_DOMAIN="gui/$(/usr/bin/id -u)"
LAUNCHD_OWNER_UID="$(/usr/bin/id -u)"
LAUNCHD_TEMPLATE_FILE="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist.in"
LAUNCHCTL_COMMAND_TIMEOUT_SECONDS=5

usage() {
  cat <<'EOF'
用法：
  08-on-demand-service.sh install [--purge]
                                   校验模型并原子安装用户 LaunchAgent plist
  08-on-demand-service.sh start [--purge]
                                   校验模型并启动/重启本用户 LaunchAgent
  08-on-demand-service.sh status        报告 launchd、网关监听、health 和后端状态
  08-on-demand-service.sh logs [target] 跟踪日志（gateway|backend|launchd|all）
  08-on-demand-service.sh stop          停止本用户 LaunchAgent，不删除 plist
  08-on-demand-service.sh uninstall [--purge]
                                   停止并只删除本工具生成的 plist
  08-on-demand-service.sh foreground   前台运行网关（不接入 launchd）

start/foreground 在 direct whisper-server 已运行或 gateway 端口被未知进程
占用时会拒绝操作，绝不自动停止或 kill 另一模式/未知 PID。
EOF
}

require_launchctl() {
  [[ -x "${LAUNCHCTL}" ]] || die "找不到 macOS launchctl：${LAUNCHCTL}"
  [[ -x "${PLUTIL}" ]] || die "找不到 macOS plutil：${PLUTIL}"
  [[ -x "${MKtemp}" ]] || die "找不到临时文件工具：${MKtemp}"
}

run_launchctl_bounded() {
  local operation="$1"; shift
  local temp_dir stdout_file stderr_file child iteration launchctl_status
  temp_dir="$("${MKtemp}" -d "${TMPDIR:-/tmp}/whisper-launchctl.XXXXXX")" || {
    warn "无法创建 launchctl 临时输出目录：${operation}"
    return 1
  }
  stdout_file="${temp_dir}/stdout"
  stderr_file="${temp_dir}/stderr"
  "${LAUNCHCTL}" "$@" >"${stdout_file}" 2>"${stderr_file}" &
  child=$!
  for ((iteration = 0; iteration < LAUNCHCTL_COMMAND_TIMEOUT_SECONDS * 10; iteration++)); do
    if ! kill -0 "${child}" 2>/dev/null; then
      if wait "${child}"; then
        launchctl_status=0
      else
        launchctl_status=$?
      fi
      cat "${stdout_file}" "${stderr_file}" 2>/dev/null || true
      rm -rf "${temp_dir}"
      return "${launchctl_status}"
    fi
    sleep 0.1
  done

  warn "launchctl ${operation} 超过 ${LAUNCHCTL_COMMAND_TIMEOUT_SECONDS} 秒；终止本脚本创建的 launchctl 子进程。"
  kill -TERM "${child}" 2>/dev/null || true
  sleep 0.2
  kill -KILL "${child}" 2>/dev/null || true
  wait "${child}" 2>/dev/null || true
  cat "${stdout_file}" "${stderr_file}" 2>/dev/null || true
  rm -rf "${temp_dir}"
  return 124
}

prepare_runtime_dirs() {
  mkdir -p "${UPLOAD_DIR}" "${GATEWAY_RUNTIME_LOG_DIR}" \
    "${LAUNCHD_LOG_DIR}" "${GATEWAY_SERVICE_BIN_DIR}" \
    "${MODEL_DIR}" \
    "$(dirname "${GATEWAY_RUNTIME_HTTPLIB_HEADER}")" \
    "${GATEWAY_RUNTIME_SOURCE_DIR}/.git"
  chmod 700 "${GATEWAY_RUNTIME_DIR}" "${GATEWAY_RUNTIME_RUN_DIR}" \
    "${GATEWAY_RUNTIME_LOG_DIR}" "${UPLOAD_DIR}"
  chmod 700 "${LAUNCHD_LOG_DIR}" "${GATEWAY_SERVICE_DIR}" \
    "${GATEWAY_SERVICE_BIN_DIR}"
  # 日志由当前普通用户创建，网关和后端不需要共享读写权限。
  touch "${GATEWAY_LOG_FILE}" "${BACKEND_LOG_FILE}" \
    "${LAUNCHD_GATEWAY_STDOUT_FILE}" "${LAUNCHD_GATEWAY_STDERR_FILE}"
  chmod 600 "${GATEWAY_LOG_FILE}" "${BACKEND_LOG_FILE}" \
    "${LAUNCHD_GATEWAY_STDOUT_FILE}" "${LAUNCHD_GATEWAY_STDERR_FILE}"
}

assert_gateway_prerequisites() {
  local prepare_runtime="${1:-1}"
  require_regular_user
  [[ "${WHISPER_SERVICE_USER}" == "$(/usr/bin/id -un)" ]] ||
    die "用户 LaunchAgent 必须由当前登录用户管理（配置 WHISPER_SERVICE_USER=${WHISPER_SERVICE_USER}，当前用户=$(/usr/bin/id -un)）。"
  [[ -x "${ON_DEMAND_BUILD_GATEWAY_BIN}" ]] ||
    die "按需网关构建产物不存在或不可执行：${ON_DEMAND_BUILD_GATEWAY_BIN}；先运行 07-build-on-demand-gateway.sh。"
  # 网关启动前重新做完整模型大小和 SHA-256 校验；不要因为冷启动成本
  # 而跳过完整性检查。源代码 commit 也必须仍是构建时审计的固定版本。
  assert_source_commit
  assert_model_valid
  if [[ "${prepare_runtime}" == "1" ]]; then
    prepare_runtime_dirs
  fi
}

assert_gateway_publish_inputs() {
  local state_file expected_sha expected_header_sha actual_sha
  state_file="${ON_DEMAND_BUILD_DIR}/gateway-build.txt"
  [[ -f "${state_file}" ]] || die "缺少网关构建状态：${state_file}"
  expected_sha="$(awk -F= '$1 == "binary_sha256" {print $2; exit}' "${state_file}")"
  [[ "${expected_sha}" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "网关构建状态缺少合法 binary_sha256：${state_file}"
  [[ -x "${ON_DEMAND_BUILD_GATEWAY_BIN}" ]] ||
    die "按需网关构建产物不存在或不可执行：${ON_DEMAND_BUILD_GATEWAY_BIN}"
  actual_sha="$(sha256_file "${ON_DEMAND_BUILD_GATEWAY_BIN}")"
  [[ "${actual_sha}" == "${expected_sha}" ]] ||
    die "网关构建产物与已验证状态不一致；请重新运行 07-build-on-demand-gateway.sh。"
  expected_header_sha="$(awk -F= '$1 == "httplib_header_sha256" {print $2; exit}' "${state_file}")"
  [[ "${expected_header_sha}" =~ ^[0-9a-fA-F]{64}$ ]] ||
    die "网关构建状态缺少合法 httplib_header_sha256：${state_file}"
  [[ -f "${SOURCE_DIR}/examples/server/httplib.h" ]] ||
    die "缺少已固定源码中的 httplib.h：${SOURCE_DIR}/examples/server/httplib.h"
  [[ "$(sha256_file "${SOURCE_DIR}/examples/server/httplib.h")" == "${expected_header_sha}" ]] ||
    die "源码 httplib.h 与已验证构建状态不一致；请重新运行 07-build-on-demand-gateway.sh。"
  [[ -x "${SERVER_BIN}" ]] ||
    die "whisper-server 构建产物不存在或不可执行：${SERVER_BIN}"
}

publish_gateway_for_service() {
  local state_file expected_sha expected_header_sha actual_sha temp_path
  local candidate_bin_dir asset
  assert_gateway_publish_inputs
  state_file="${ON_DEMAND_BUILD_DIR}/gateway-build.txt"
  [[ -f "${state_file}" ]] || die "缺少网关构建状态：${state_file}"
  expected_sha="$(awk -F= '$1 == "binary_sha256" {print $2; exit}' "${state_file}")"
  [[ "${expected_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
    die "网关构建状态缺少合法 binary_sha256：${state_file}"
  actual_sha="$(sha256_file "${ON_DEMAND_BUILD_GATEWAY_BIN}")"
  [[ "${actual_sha}" == "${expected_sha}" ]] || \
    die "网关构建产物与已验证状态不一致；请重新运行 07-build-on-demand-gateway.sh。"
  expected_header_sha="$(awk -F= '$1 == "httplib_header_sha256" {print $2; exit}' "${state_file}")"
  [[ "${expected_header_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || \
    die "网关构建状态缺少合法 httplib_header_sha256：${state_file}"

  temp_path="$(${MKtemp} "${GATEWAY_SERVICE_BIN_DIR}/.gateway.XXXXXX")" || \
    die "无法创建服务二进制临时文件。"
  if ! install -m 0755 "${ON_DEMAND_BUILD_GATEWAY_BIN}" "${temp_path}"; then
    rm -f -- "${temp_path}"
    die "无法暂存服务二进制。"
  fi
  # Replace the linker's transient signature with a complete ad-hoc signature
  # before launchd opens the file.  No identity or entitlement is asserted.
  if ! /usr/bin/codesign --force --sign - "${temp_path}" >/dev/null; then
    rm -f -- "${temp_path}"
    die "服务二进制 ad-hoc 签名失败。"
  fi
  if [[ -f "${GATEWAY_BIN}" ]]; then
    cp -p "${GATEWAY_BIN}" "${GATEWAY_BIN}.previous.tmp" || {
      rm -f -- "${temp_path}"
      die "无法保留旧服务二进制。"
    }
  fi
  mv -f "${temp_path}" "${GATEWAY_BIN}"
  if [[ -f "${GATEWAY_BIN}.previous.tmp" ]]; then
    mv -f "${GATEWAY_BIN}.previous.tmp" "${GATEWAY_BIN}.previous"
  fi

  candidate_bin_dir="$(${MKtemp} -d "${GATEWAY_SERVICE_DIR}/candidate-bin.XXXXXX")" || \
    die "无法创建 whisper-server 候选目录。"
  install -m 0755 "${SERVER_BIN}" "${candidate_bin_dir}/whisper-server" || {
    rm -rf -- "${candidate_bin_dir}"
    die "无法暂存 whisper-server。"
  }
  /bin/cp -pP "${BIN_DIR}/"lib*.dylib "${candidate_bin_dir}/" || {
    rm -rf -- "${candidate_bin_dir}"
    die "无法暂存 whisper-server 运行库。"
  }
  for asset in "${candidate_bin_dir}"/lib*.dylib; do
    [[ -f "${asset}" && ! -L "${asset}" ]] || continue
    if /usr/bin/otool -l "${asset}" | /usr/bin/grep -F \
      "path ${BIN_DIR} " >/dev/null; then
      /usr/bin/install_name_tool -rpath "${BIN_DIR}" @loader_path \
        "${asset}" || {
        rm -rf -- "${candidate_bin_dir}"
        die "无法修正运行库 rpath：${asset}"
      }
    fi
    /usr/bin/codesign --force --sign - "${asset}" >/dev/null || {
      rm -rf -- "${candidate_bin_dir}"
      die "运行库 ad-hoc 签名失败：${asset}"
    }
  done
  /usr/bin/install_name_tool -rpath "${BIN_DIR}" @executable_path \
    "${candidate_bin_dir}/whisper-server" || {
    rm -rf -- "${candidate_bin_dir}"
    die "无法修正 whisper-server rpath。"
  }
  /usr/bin/codesign --force --sign - \
    "${candidate_bin_dir}/whisper-server" >/dev/null || {
    rm -rf -- "${candidate_bin_dir}"
    die "whisper-server ad-hoc 签名失败。"
  }
  for asset in "${candidate_bin_dir}"/*; do
    mv -f "${asset}" "${GATEWAY_SERVICE_BIN_DIR}/"
  done
  rmdir "${candidate_bin_dir}"

  temp_path="$(${MKtemp} "$(dirname "${GATEWAY_RUNTIME_HTTPLIB_HEADER}")/.httplib.XXXXXX")" || \
    die "无法创建 httplib.h 临时文件。"
  install -m 0600 "${SOURCE_DIR}/examples/server/httplib.h" "${temp_path}" || {
    rm -f -- "${temp_path}"
    die "无法复制 pinned httplib.h。"
  }
  [[ "$(sha256_file "${temp_path}")" == "${expected_header_sha}" ]] || {
    rm -f -- "${temp_path}"
    die "服务运行时 httplib.h 校验失败。"
  }
  mv -f "${temp_path}" "${GATEWAY_RUNTIME_HTTPLIB_HEADER}"

  temp_path="$(${MKtemp} "${GATEWAY_RUNTIME_SOURCE_DIR}/.git/.HEAD.XXXXXX")" || \
    die "无法创建 commit attestation 临时文件。"
  printf '%s\n' "${WHISPER_COMMIT}" >"${temp_path}"
  chmod 0600 "${temp_path}"
  mv -f "${temp_path}" "${GATEWAY_RUNTIME_SOURCE_DIR}/.git/HEAD"
  log "已把验证过的最小运行时原子部署到：${GATEWAY_SERVICE_DIR}"
}

build_gateway_command() {
  GATEWAY_COMMAND=(
    "${GATEWAY_BIN}"
    --gateway-host "${ON_DEMAND_GATEWAY_HOST}"
    --gateway-port "${WHISPER_GATEWAY_PORT}"
    --backend-port "${WHISPER_BACKEND_PORT}"
    --backend-bin "${GATEWAY_RUNTIME_SERVER_BIN}"
    --model "${MODEL_FILE}"
    --model-size "${WHISPER_MODEL_SIZE_BYTES}"
    --model-sha256 "${WHISPER_MODEL_SHA256}"
    --source-dir "${GATEWAY_RUNTIME_SOURCE_DIR}"
    --source-commit "${WHISPER_COMMIT}"
    --httplib-header "${GATEWAY_RUNTIME_HTTPLIB_HEADER}"
    --inference-path "${WHISPER_INFERENCE_PATH}"
    --language "${WHISPER_LANGUAGE}"
    --threads "${WHISPER_THREADS}"
    --gateway-pid-file "${GATEWAY_PID_FILE}"
    --backend-pid-file "${BACKEND_PID_FILE}"
    --upload-dir "${UPLOAD_DIR}"
    --backend-log-file "${BACKEND_LOG_FILE}"
    --idle-timeout-seconds "${WHISPER_IDLE_TIMEOUT_SECONDS}"
    --startup-timeout-seconds "${WHISPER_STARTUP_TIMEOUT_SECONDS}"
    --shutdown-timeout-seconds "${WHISPER_SHUTDOWN_TIMEOUT_SECONDS}"
    --request-timeout-seconds "${WHISPER_REQUEST_TIMEOUT_SECONDS}"
    --max-pending-requests "${WHISPER_MAX_PENDING_REQUESTS}"
    --max-upload-bytes "${WHISPER_MAX_UPLOAD_BYTES}"
    --start-failure-backoff-seconds "${WHISPER_START_FAILURE_BACKOFF_SECONDS}"
  )
}

xml_escape() {
  local value="${1:-}"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "${value}"
}

plist_owner_is_current() {
  [[ -f "${LAUNCHD_PLIST_FILE}" ]] || return 1
  local owner
  owner="$(/usr/bin/stat -f '%u' "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
  [[ "${owner}" == "${LAUNCHD_OWNER_UID}" ]]
}

plist_program_arguments_match() {
  local index=0 expected actual extra
  for expected in "${GATEWAY_COMMAND[@]}"; do
    actual="$("${PLUTIL}" -extract "ProgramArguments.${index}" raw -o - \
      "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
    [[ "${actual}" == "${expected}" ]] || return 1
    index=$((index + 1))
  done
  extra="$("${PLUTIL}" -extract "ProgramArguments.${index}" raw -o - \
    "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
  [[ -z "${extra}" ]]
}

plist_identity_is_ours() {
  [[ -f "${LAUNCHD_PLIST_FILE}" ]] || return 1
  build_gateway_command
  local label managed managed_legacy program
  label="$("${PLUTIL}" -extract Label raw -o - "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
  managed="$("${PLUTIL}" -extract "EnvironmentVariables.${LAUNCHD_MANAGED_ENV_KEY}" raw -o - \
    "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
  managed_legacy="$("${PLUTIL}" -extract ManagedBy raw -o - \
    "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
  program="$("${PLUTIL}" -extract 'ProgramArguments.0' raw -o - "${LAUNCHD_PLIST_FILE}" 2>/dev/null || true)"
  [[ "${label}" == "${LAUNCHD_LABEL}" ]] || return 1
  # 新模板把归属标记放入 EnvironmentVariables，避免 launchd 对自定义顶层
  # ManagedBy 键发出 Unknown key；兼容本工具旧版本的同一 label 以便升级。
  [[ "${managed}" == "${LAUNCHD_MANAGED_BY}" || \
    ( -z "${managed}" && "${managed_legacy}" == "${LAUNCHD_MANAGED_BY}" ) ]] || return 1
  plist_owner_is_current || return 1
  [[ "${program}" == "${GATEWAY_BIN}" || \
     "${program}" == "${ON_DEMAND_BUILD_GATEWAY_BIN}" ]]
}

plist_belongs_to_us() {
  plist_identity_is_ours || return 1
  plist_program_arguments_match
}

write_plist_atomic() {
  local launch_agents_dir temp_file line escaped_label escaped_managed
  local escaped_working_directory escaped_stdout escaped_stderr
  local exit_timeout in_program_arguments=0
  launch_agents_dir="$(dirname "${LAUNCHD_PLIST_FILE}")"
  mkdir -p "${launch_agents_dir}"
  [[ -d "${launch_agents_dir}" ]] || die "无法创建 LaunchAgents 目录：${launch_agents_dir}"

  build_gateway_command
  if [[ -f "${LAUNCHD_PLIST_FILE}" ]] && ! plist_identity_is_ours; then
    die "拒绝覆盖非本工具生成的 plist：${LAUNCHD_PLIST_FILE}"
  fi

  [[ -f "${LAUNCHD_TEMPLATE_FILE}" ]] ||
    die "找不到 LaunchAgent 单一模板：${LAUNCHD_TEMPLATE_FILE}"
  umask 077
  temp_file="$("${MKtemp}" "${launch_agents_dir}/.${LAUNCHD_LABEL}.plist.XXXXXX")" ||
    die "无法创建临时 plist。"

  escaped_label="$(xml_escape "${LAUNCHD_LABEL}")"
  escaped_managed="$(xml_escape "${LAUNCHD_MANAGED_BY}")"
  # Do not give launchd a working directory under ~/Documents.  On current
  # macOS, a child shell can block in getcwd() before exec when launched from
  # that protected location.  All runtime paths are absolute.
  escaped_working_directory="$(xml_escape "${GATEWAY_SERVICE_DIR}")"
  escaped_stdout="$(xml_escape "${LAUNCHD_GATEWAY_STDOUT_FILE}")"
  escaped_stderr="$(xml_escape "${LAUNCHD_GATEWAY_STDERR_FILE}")"
  exit_timeout=$((WHISPER_SHUTDOWN_TIMEOUT_SECONDS + 5))
  if (( exit_timeout < 20 )); then
    exit_timeout=20
  fi

  {
    while IFS= read -r line || [[ -n "${line}" ]]; do
      if [[ "${line}" == *"<!-- BEGIN_PROGRAM_ARGUMENTS -->"* ]]; then
        printf '%s\n' "${line}"
        in_program_arguments=1
        continue
      fi
      if [[ "${line}" == *"<!-- END_PROGRAM_ARGUMENTS -->"* ]]; then
        (( in_program_arguments == 1 )) || die "LaunchAgent 模板缺少 ProgramArguments 起始标记。"
        for arg in "${GATEWAY_COMMAND[@]}"; do
          printf '    <string>%s</string>\n' "$(xml_escape "${arg}")"
        done
        printf '%s\n' "${line}"
        in_program_arguments=0
        continue
      fi
      if [[ "${line}" == *"<!-- EXIT_TIMEOUT_SETTING -->"* ]]; then
        printf '  <key>ExitTimeOut</key>\n  <integer>%s</integer>\n' "${exit_timeout}"
        continue
      fi
      if (( in_program_arguments == 1 )); then
        continue
      fi

      line="${line//__LAUNCHD_LABEL__/${escaped_label}}"
      line="${line//__MANAGED_BY__/${escaped_managed}}"
      line="${line//__WORKING_DIRECTORY__/${escaped_working_directory}}"
      line="${line//__STDOUT_PATH__/${escaped_stdout}}"
      line="${line//__STDERR_PATH__/${escaped_stderr}}"
      printf '%s\n' "${line}"
    done <"${LAUNCHD_TEMPLATE_FILE}"
  } >"${temp_file}"

  if (( in_program_arguments != 0 )); then
    rm -f "${temp_file}"
    die "LaunchAgent 模板缺少 ProgramArguments 结束标记。"
  fi
  if /usr/bin/grep -Eq '__[A-Z0-9_]+__' "${temp_file}"; then
    rm -f "${temp_file}"
    die "渲染的 LaunchAgent plist 仍含未替换占位符。"
  fi
  chmod 600 "${temp_file}"

  if ! "${PLUTIL}" -lint "${temp_file}" >/dev/null; then
    rm -f "${temp_file}"
    die "生成的 LaunchAgent plist 未通过 plutil 校验。"
  fi
  mv -f "${temp_file}" "${LAUNCHD_PLIST_FILE}"
  chmod 600 "${LAUNCHD_PLIST_FILE}"
  plist_owner_is_current || die "生成的 LaunchAgent plist 所有者不是当前用户。"
  plist_belongs_to_us || die "生成的 LaunchAgent plist 参数或所有权校验失败。"
  log "LaunchAgent plist 已原子安装：${LAUNCHD_PLIST_FILE}"
}

assert_on_demand_port_available() {
  local allow_loaded_gateway="${1:-0}"
  if direct_mode_is_running; then
    die "检测到 direct whisper-server 正在运行；拒绝启动按需网关，绝不自动停止另一模式。请先执行 scripts/05-server.sh stop。"
  fi

  local own_gateway_pid="" listener_pid listener_command
  if [[ -f "${GATEWAY_PID_FILE}" ]]; then
    own_gateway_pid="$(pid_from_file "${GATEWAY_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${own_gateway_pid}" ]] && pid_is_our_gateway "${own_gateway_pid}"; then
      if [[ "${allow_loaded_gateway}" == "1" ]] && launchd_service_loaded; then
        :
      else
        die "检测到自有 gateway 已在前台或由未知方式运行（PID=${own_gateway_pid}）；拒绝重复启动，且不会自动 kill。"
      fi
    fi
  fi

  while IFS= read -r listener_pid; do
    [[ -n "${listener_pid}" ]] || continue
    if pid_is_our_gateway "${listener_pid}"; then
      # 只有已经由本用户 launchd 管理的自有实例允许进入重启流程；未加载
      # launchd 的前台实例必须由操作者明确停止，不能被本脚本接管。
      if [[ "${allow_loaded_gateway}" == "1" ]] && launchd_service_loaded; then
        continue
      fi
      die "网关端口由自有前台/未托管 gateway 占用（PID=${listener_pid}）；拒绝启动且不会 kill。"
    fi
    listener_command="$(/bin/ps -p "${listener_pid}" -o command= 2>/dev/null || true)"
    die "网关端口 ${WHISPER_GATEWAY_PORT} 已被未知进程占用（PID=${listener_pid}，${listener_command:-命令不可读}）；拒绝启动且不会 kill。"
  done < <(listener_pids_for_port "${WHISPER_GATEWAY_PORT}")
}

process_ids_for_exact_executable() {
  local expected="$1" pid command
  while read -r pid command; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    case "${command}" in
      "${expected}"|"${expected} "*) printf '%s\n' "${pid}" ;;
    esac
  done < <(/bin/ps -axo pid=,command= 2>/dev/null || true)
}

assert_purge_process_safety() {
  local allow_own_gateway="${1:-1}" pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    if [[ "${allow_own_gateway}" == "1" ]] && pid_is_our_gateway "${pid}"; then
      continue
    fi
    die "Application Support 二进制仍被进程使用（PID=${pid}）；拒绝 purge。"
  done < <(process_ids_for_exact_executable "${GATEWAY_BIN}")

  # A backend is never allowed during a purge preflight: a cold gateway has
  # no backend process, and an unknown process at this path must not survive
  # deletion of its executable.
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    die "Application Support whisper-server 仍被进程使用（PID=${pid}）；拒绝 purge。"
  done < <(process_ids_for_exact_executable "${GATEWAY_RUNTIME_SERVER_BIN}")
}

assert_purge_listener_safety() {
  local allow_own_gateway="${1:-1}" port pid
  for port in "${WHISPER_GATEWAY_PORT}" "${WHISPER_BACKEND_PORT}"; do
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      if [[ "${port}" == "${WHISPER_GATEWAY_PORT}" && \
        "${allow_own_gateway}" == "1" ]] && pid_is_our_gateway "${pid}"; then
        continue
      fi
      die "端口 ${port} 仍被未知或不安全进程占用（PID=${pid}）；拒绝 purge。"
    done < <(listener_pids_for_port "${port}")
  done
}

assert_purge_runtime_preflight() {
  local allow_own_gateway="${1:-1}"
  validate_purge_model
  assert_purge_process_safety "${allow_own_gateway}"
  assert_purge_listener_safety "${allow_own_gateway}"
}

launchd_service_target() {
  printf '%s/%s' "${LAUNCHD_DOMAIN}" "${LAUNCHD_LABEL}"
}

launchd_service_loaded() {
  run_launchctl_bounded "print $(launchd_service_target)" \
    print "$(launchd_service_target)" >/dev/null 2>&1
}

runtime_is_gone() {
  [[ ! -e "${GATEWAY_PID_FILE}" ]] || return 1
  [[ ! -e "${BACKEND_PID_FILE}" ]] || return 1
  [[ -z "$(listener_pids_for_port "${WHISPER_GATEWAY_PORT}")" ]] || return 1
  [[ -z "$(listener_pids_for_port "${WHISPER_BACKEND_PORT}")" ]]
}

report_runtime_shutdown_timeout() {
  warn "网关/后端未在退出等待窗口内完全消失；不会 SIGKILL、不会删除 PID 文件，也不会触碰未知进程。"
  if [[ -e "${GATEWAY_PID_FILE}" ]]; then
    warn "仍存在 gateway PID 文件：${GATEWAY_PID_FILE}"
  fi
  if [[ -e "${BACKEND_PID_FILE}" ]]; then
    warn "仍存在 backend PID 文件：${BACKEND_PID_FILE}"
  fi
  listener_pids_for_port "${WHISPER_GATEWAY_PORT}" | while IFS= read -r listener_pid; do
    [[ -n "${listener_pid}" ]] || continue
    warn "gateway 端口仍被 PID=${listener_pid} 占用。"
  done
  listener_pids_for_port "${WHISPER_BACKEND_PORT}" | while IFS= read -r listener_pid; do
    [[ -n "${listener_pid}" ]] || continue
    warn "backend 端口仍被 PID=${listener_pid} 占用。"
  done
}

wait_for_runtime_shutdown() {
  local timeout_seconds deadline
  timeout_seconds=$((WHISPER_SHUTDOWN_TIMEOUT_SECONDS + 5))
  if (( timeout_seconds < 20 )); then
    timeout_seconds=20
  fi
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if runtime_is_gone; then
      return 0
    fi
    sleep 0.5
  done
  report_runtime_shutdown_timeout
  return 1
}

bootout_our_service() {
  if launchd_service_loaded; then
    plist_identity_is_ours ||
      die "LaunchAgent label ${LAUNCHD_LABEL} 已加载，但 plist 不是本工具生成的；拒绝 bootout 未知服务。"
    log "停止本用户 LaunchAgent：${LAUNCHD_LABEL}"
    run_launchctl_bounded "bootout $(launchd_service_target)" \
      bootout "$(launchd_service_target)" ||
      die "无法停止本用户 LaunchAgent；未尝试停止其他服务。"
  else
    log "LaunchAgent 未加载：${LAUNCHD_LABEL}"
  fi
  wait_for_runtime_shutdown || return 1
}

purge_runtime_is_gone() {
  local pid_file pid
  for pid_file in "${GATEWAY_PID_FILE}" "${BACKEND_PID_FILE}"; do
    [[ ! -e "${pid_file}" ]] && continue
    pid="$(pid_from_file "${pid_file}" 2>/dev/null || true)"
    [[ -n "${pid}" ]] || return 1
    kill -0 "${pid}" 2>/dev/null && return 1
  done
  [[ -z "$(listener_pids_for_port "${WHISPER_GATEWAY_PORT}")" ]] || return 1
  [[ -z "$(listener_pids_for_port "${WHISPER_BACKEND_PORT}")" ]]
}

wait_for_purge_runtime_shutdown() {
  local timeout_seconds deadline
  timeout_seconds=$((WHISPER_SHUTDOWN_TIMEOUT_SECONDS + 5))
  if (( timeout_seconds < 20 )); then
    timeout_seconds=20
  fi
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    purge_runtime_is_gone && return 0
    sleep 0.5
  done
  report_runtime_shutdown_timeout
  return 1
}

bootout_our_service_for_purge() {
  if launchd_service_loaded; then
    plist_identity_is_ours ||
      die "LaunchAgent label ${LAUNCHD_LABEL} 已加载，但 plist 不是本工具生成的；拒绝 purge 未知服务。"
    log "停止本用户 LaunchAgent（purge）：${LAUNCHD_LABEL}"
    run_launchctl_bounded "bootout $(launchd_service_target)" \
      bootout "$(launchd_service_target)" ||
      die "无法停止本用户 LaunchAgent；未执行 purge。"
  else
    log "LaunchAgent 未加载：${LAUNCHD_LABEL}"
  fi
  wait_for_purge_runtime_shutdown ||
    die "按需运行时未完全退出；拒绝删除 Application Support。"
}

bootstrap_our_service() {
  if ! run_launchctl_bounded "bootstrap ${LAUNCHD_PLIST_FILE}" \
    bootstrap "${LAUNCHD_DOMAIN}" "${LAUNCHD_PLIST_FILE}"; then
    if ! launchd_service_loaded; then
      warn "无法 bootstrap LaunchAgent：${LAUNCHD_PLIST_FILE}"
      return 1
    fi
    if ! plist_identity_is_ours; then
      warn "同名 LaunchAgent 已加载但不属于本工具；拒绝 kickstart 未知服务。"
      return 1
    fi
    warn "LaunchAgent 已加载，继续 kickstart 本工具自有 label。"
  fi
  # RunAtLoad 已由 bootstrap 触发启动。不要再使用 kickstart -k：在模型
  # 完整性校验/绑定尚未完成时它会强制终止刚启动的 gateway，并且某些
  # macOS 版本会让 kickstart 自身等待 KeepAlive 重试，造成假失败或卡住。
}

gateway_process_is_ready() {
  local gateway_pid=""
  gateway_pid="$(pid_from_file "${GATEWAY_PID_FILE}" 2>/dev/null || true)"
  [[ -n "${gateway_pid}" ]] && pid_is_our_gateway "${gateway_pid}"
}

gateway_health_is_ok() {
  local response
  response="$(curl --silent --show-error --max-time 3 "$(gateway_health_url)" 2>/dev/null || true)"
  [[ "${response}" == *'"status":"ok"'* ]]
}

assert_gateway_safe_to_replace() {
  local response=""
  if ! launchd_service_loaded && ! gateway_process_is_ready; then
    return 0
  fi
  response="$(curl --silent --show-error --max-time 3 \
    "$(gateway_health_url)" 2>/dev/null || true)"
  [[ -n "${response}" ]] || \
    die "旧网关仍由本工具管理但 health 不可读；拒绝盲目重启，请先排障或显式 stop。"
  [[ "${response}" == *'"status":"ok"'* && \
     "${response}" == *'"backend":"cold"'* && \
     "${response}" == *'"active_requests":0'* && \
     "${response}" == *'"pending_requests":0'* ]] || \
    die "旧网关不是 cold/零请求状态；拒绝中断在线请求：${response}"
}

wait_for_gateway_start() {
  local deadline
  deadline=$((SECONDS + WHISPER_STARTUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if launchd_service_loaded && gateway_process_is_ready && gateway_health_is_ok; then
      return 0
    fi
    sleep 1
  done
  return 1
}

report_start_failure() {
  warn "按需网关启动失败或未在 ${WHISPER_STARTUP_TIMEOUT_SECONDS} 秒内完成 PID+/health 验证。"
  warn "launchctl 状态尾部："
  run_launchctl_bounded "print $(launchd_service_target)" \
    print "$(launchd_service_target)" 2>&1 | "${TAIL}" -n 100 >&2 || true
  warn "gateway stderr 尾部：${LAUNCHD_GATEWAY_STDERR_FILE}"
  "${TAIL}" -n 100 "${LAUNCHD_GATEWAY_STDERR_FILE}" >&2 || true
  warn "gateway stdout 尾部：${LAUNCHD_GATEWAY_STDOUT_FILE}"
  "${TAIL}" -n 100 "${LAUNCHD_GATEWAY_STDOUT_FILE}" >&2 || true
  warn "backend 日志尾部：${BACKEND_LOG_FILE}"
  "${TAIL}" -n 100 "${BACKEND_LOG_FILE}" >&2 || true
}

install_service() {
  local purge_requested="${1:-0}"
  if [[ "${purge_requested}" == "1" ]]; then
    require_launchctl
    # Everything needed for a later redeploy is checked before bootout or
    # deletion.  The prerequisite call deliberately skips directory creation.
    assert_gateway_prerequisites 0
    assert_gateway_publish_inputs
    if [[ -f "${LAUNCHD_PLIST_FILE}" ]]; then
      plist_identity_is_ours ||
        die "拒绝 purge 非本工具生成的 plist：${LAUNCHD_PLIST_FILE}"
    fi
    assert_purge_runtime_preflight 1
    assert_gateway_safe_to_replace
    bootout_our_service_for_purge
    assert_purge_runtime_preflight 0
    purge_application_support
  fi
  assert_gateway_prerequisites
  assert_gateway_safe_to_replace
  publish_gateway_for_service
  write_plist_atomic
}

start_service() {
  local purge_requested="${1:-0}"
  require_launchctl
  assert_on_demand_port_available 1
  if [[ "${purge_requested}" == "1" ]]; then
    # Validate the model, deployment proof, process identity, and both service
    # ports before allowing the cold/zero-request gateway to be booted out.
    assert_gateway_prerequisites 0
    assert_gateway_publish_inputs
    if [[ -f "${LAUNCHD_PLIST_FILE}" ]]; then
      plist_identity_is_ours ||
        die "拒绝 purge 非本工具生成的 plist：${LAUNCHD_PLIST_FILE}"
    fi
    assert_purge_runtime_preflight 1
    assert_gateway_safe_to_replace
    bootout_our_service_for_purge
    assert_purge_runtime_preflight 0
    purge_application_support
  fi
  assert_gateway_prerequisites
  assert_gateway_safe_to_replace
  publish_gateway_for_service
  write_plist_atomic
  # 只 bootout 自己的 label，确保改过的 ProgramArguments 原子生效；不
  # 触碰 direct server 或任何 PID 文件指向的未知进程。
  if ! bootout_our_service; then
    die "旧的按需服务未在安全退出窗口内完全停止；拒绝启动新实例。"
  fi
  if ! bootstrap_our_service; then
    report_start_failure
    bootout_our_service || warn "启动失败后的自有 LaunchAgent 清理未完全成功；不会 kill 未知进程。"
    return 1
  fi
  if ! wait_for_gateway_start; then
    report_start_failure
    bootout_our_service || warn "启动失败后的自有 LaunchAgent 清理未完全成功；不会 kill 未知进程。"
    return 1
  fi
  log "按需网关启动请求已提交：$(gateway_health_url)"
}

status_service() {
  require_regular_user
  require_command curl
  require_launchctl

  local gateway_pid="" gateway_command="" listener_pid listener_command
  local health_response="" backend_listeners=""
  if launchd_service_loaded; then
    printf 'launchd: loaded (%s)\n' "$(launchd_service_target)"
  else
    printf 'launchd: unloaded (%s)\n' "$(launchd_service_target)"
  fi

  if [[ -f "${GATEWAY_PID_FILE}" ]]; then
    gateway_pid="$(pid_from_file "${GATEWAY_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${gateway_pid}" ]] && pid_is_our_gateway "${gateway_pid}"; then
      gateway_command="$(/bin/ps -p "${gateway_pid}" -o command= 2>/dev/null || true)"
      printf 'gateway: running PID=%s%s\n' "${gateway_pid}" \
        "${gateway_command:+ (${gateway_command})}"
    else
      printf 'gateway: stale/unknown PID file=%s（不会 kill）\n' "${gateway_pid:-无法解析}"
    fi
  else
    printf 'gateway: no PID file (%s)\n' "${GATEWAY_PID_FILE}"
  fi

  listener_pids_for_port "${WHISPER_GATEWAY_PORT}" | while IFS= read -r listener_pid; do
    [[ -n "${listener_pid}" ]] || continue
    listener_command="$(/bin/ps -p "${listener_pid}" -o command= 2>/dev/null || true)"
    printf 'gateway-listener: PID=%s%s\n' "${listener_pid}" \
      "${listener_command:+ (${listener_command})}"
  done

  health_response="$(curl --silent --show-error --max-time 3 "$(gateway_health_url)" 2>/dev/null || true)"
  if [[ -n "${health_response}" ]]; then
    printf 'health: %s\n' "${health_response}"
  else
    printf 'health: unavailable (%s)\n' "$(gateway_health_url)"
  fi

  backend_listeners="$(listener_pids_for_port "${WHISPER_BACKEND_PORT}")"
  if [[ -z "${backend_listeners}" ]]; then
    printf 'backend: no listener (cold or not ready)\n'
  else
    while IFS= read -r listener_pid; do
      [[ -n "${listener_pid}" ]] || continue
      listener_command="$(/bin/ps -p "${listener_pid}" -o command= 2>/dev/null || true)"
      printf 'backend-listener: PID=%s%s\n' "${listener_pid}" \
        "${listener_command:+ (${listener_command})}"
    done <<<"${backend_listeners}"
  fi
}

logs_service() {
  local target_name="${1:-gateway}" paths=()
  case "${target_name}" in
    gateway)
      paths=("${LAUNCHD_GATEWAY_STDOUT_FILE}" "${LAUNCHD_GATEWAY_STDERR_FILE}")
      ;;
    backend)
      paths=("${BACKEND_LOG_FILE}")
      ;;
    launchd)
      paths=("${LAUNCHD_GATEWAY_STDOUT_FILE}" "${LAUNCHD_GATEWAY_STDERR_FILE}")
      ;;
    all)
      paths=("${LAUNCHD_GATEWAY_STDOUT_FILE}" "${LAUNCHD_GATEWAY_STDERR_FILE}" \
        "${BACKEND_LOG_FILE}")
      ;;
    *)
      die "logs target 只能是 gateway、backend、launchd 或 all：${target_name}"
      ;;
  esac
  local path
  for path in "${paths[@]}"; do
    [[ -f "${path}" ]] || die "日志不存在：${path}"
  done
  exec "${TAIL}" -n 100 -f "${paths[@]}"
}

stop_service() {
  require_regular_user
  require_launchctl
  bootout_our_service
}

uninstall_service() {
  local purge_requested="${1:-0}"
  require_regular_user
  require_launchctl
  if [[ -f "${LAUNCHD_PLIST_FILE}" ]]; then
    plist_identity_is_ours ||
      die "拒绝操作非本工具生成的 plist：${LAUNCHD_PLIST_FILE}"
  fi
  if [[ "${purge_requested}" == "1" ]]; then
    # A missing model is allowed for an uninstall, but a present model must
    # pass the same integrity/ownership/mode checks as install/start purge.
    # Do not inspect/deny an owned backend before the explicit uninstall
    # bootout: ordinary uninstall semantics stop the owned service first and
    # then wait for its gateway/backend children to disappear.
    validate_purge_model
    bootout_our_service_for_purge
    assert_purge_runtime_preflight 0
  else
    bootout_our_service
  fi
  if [[ -f "${LAUNCHD_PLIST_FILE}" ]]; then
    rm -f "${LAUNCHD_PLIST_FILE}"
    if [[ "${purge_requested}" == "1" ]]; then
      log "已删除本工具生成的 LaunchAgent plist。"
    else
      log "已删除本工具生成的 LaunchAgent plist；日志和运行目录保留。"
    fi
  else
    log "本工具的 LaunchAgent plist 不存在，无需删除。"
  fi
  if [[ "${purge_requested}" == "1" ]]; then
    purge_application_support
  fi
}

foreground_service() {
  require_launchctl
  if launchd_service_loaded; then
    die "本用户 LaunchAgent 已加载；拒绝启动未托管前台 gateway，请先执行 stop。"
  fi
  assert_on_demand_port_available 0
  assert_gateway_prerequisites
  publish_gateway_for_service
  build_gateway_command
  log "前台启动按需网关：$(gateway_health_url)"
  exec "${GATEWAY_COMMAND[@]}"
}

parse_purge_flags() {
  PURGE_REQUESTED=0
  local option
  while (( $# > 0 )); do
    option="$1"
    shift
    case "${option}" in
      --purge)
        (( PURGE_REQUESTED == 0 )) || {
          printf '错误：--purge 不能重复指定。\n' >&2
          exit 2
        }
        PURGE_REQUESTED=1
        ;;
      *)
        printf '错误：该子命令不支持参数：%s\n' "${option}" >&2
        exit 2
        ;;
    esac
  done
}

action="${1:-}"
case "${action}" in
  install)
    shift
    parse_purge_flags "$@"
    install_service "${PURGE_REQUESTED}"
    ;;
  start)
    shift
    parse_purge_flags "$@"
    start_service "${PURGE_REQUESTED}"
    ;;
  status)
    shift
    (( $# == 0 )) || { printf '错误：status 不接受额外参数。\n' >&2; exit 2; }
    status_service
    ;;
  logs)
    shift
    (( $# <= 1 )) || { printf '错误：logs 最多接受一个 target。\n' >&2; exit 2; }
    [[ "${1:-}" != "--purge" ]] || {
      printf '错误：logs 不支持 --purge。\n' >&2
      exit 2
    }
    logs_service "${1:-gateway}"
    ;;
  stop)
    shift
    (( $# == 0 )) || { printf '错误：stop 不接受额外参数。\n' >&2; exit 2; }
    stop_service
    ;;
  uninstall)
    shift
    parse_purge_flags "$@"
    uninstall_service "${PURGE_REQUESTED}"
    ;;
  foreground)
    shift
    (( $# == 0 )) || { printf '错误：foreground 不接受额外参数。\n' >&2; exit 2; }
    foreground_service
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    [[ -z "${action}" ]] || exit 2
    ;;
esac
