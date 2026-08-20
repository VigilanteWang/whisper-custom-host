#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user

usage() {
  cat <<'EOF'
用法：
  05-server.sh start       后台启动，写 PID 和日志；用于第 4-5 步验收
  05-server.sh foreground  前台启动，Ctrl-C 停止
  05-server.sh status      检查进程与 /health
  05-server.sh logs        跟踪日志
  05-server.sh stop        停止由本脚本启动的后台进程

注意：这是 direct 回滚模式。按需网关运行时拒绝启动 direct，且不会自动
停止另一模式；切换请先由操作者明确执行对应模式的 stop。
EOF
}

server_command=(
  "${SERVER_BIN}"
  --host "${WHISPER_HOST}"
  --port "${WHISPER_PORT}"
  --public "${SOURCE_DIR}/examples/server/public"
  --inference-path "${WHISPER_INFERENCE_PATH}"
  --convert
  --language "${WHISPER_LANGUAGE}"
  --threads "${WHISPER_THREADS}"
  --model "${MODEL_FILE}"
)

prepare() {
  [[ -x "${SERVER_BIN}" ]] || die "server 不存在：${SERVER_BIN}；先构建。"
  assert_model_valid
  require_command ffmpeg
  require_command curl
  mkdir -p "${RUN_DIR}" "${LOG_DIR}"
}

assert_direct_mode_available() {
  if on_demand_mode_is_running; then
    die "检测到按需网关正在运行（${GATEWAY_BIN}）；拒绝启动 direct，绝不自动停止另一模式。请先执行 scripts/08-on-demand-service.sh stop。"
  fi
}

wait_for_health() {
  local response
  for _ in $(/usr/bin/seq 1 120); do
    response="$(curl --silent --show-error --max-time 2 "$(health_url)" 2>/dev/null || true)"
    if [[ "${response}" == *'"status":"ok"'* ]]; then
      log "健康检查通过：$(health_url)"
      return 0
    fi
    sleep 1
  done
  return 1
}

start_server() {
  assert_direct_mode_available
  prepare

  if [[ -f "${SERVER_PID_FILE}" ]]; then
    old_pid="$(pid_from_file "${SERVER_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && pid_is_our_server "${old_pid}"; then
      die "server 已运行，PID=${old_pid}。"
    fi
    warn "移除失效 PID 文件：${SERVER_PID_FILE}"
    rm -f "${SERVER_PID_FILE}"
  fi

  if /usr/sbin/lsof -nP -iTCP:"${WHISPER_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    /usr/sbin/lsof -nP -iTCP:"${WHISPER_PORT}" -sTCP:LISTEN >&2 || true
    die "端口 ${WHISPER_PORT} 已被占用。"
  fi

  log "后台启动 whisper-server；日志：${SERVER_LOG_FILE}"
  nohup "${server_command[@]}" >>"${SERVER_LOG_FILE}" 2>&1 &
  server_pid=$!
  printf '%s\n' "${server_pid}" > "${SERVER_PID_FILE}"

  if ! wait_for_health; then
    warn "120 秒内未通过健康检查。最近日志如下："
    /usr/bin/tail -n 80 "${SERVER_LOG_FILE}" >&2 || true
    die "server 启动失败或模型仍未就绪。"
  fi

  log "server 已运行，PID=${server_pid}"
  log "本机 endpoint：$(server_url)"
  print_lan_addresses
}

print_lan_addresses() {
  local found=0 interface ip
  while IFS= read -r interface; do
    ip="$(/usr/sbin/ipconfig getifaddr "${interface}" 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      printf '局域网 endpoint（%s）：http://%s:%s%s\n' \
        "${interface}" "${ip}" "${WHISPER_PORT}" "${WHISPER_INFERENCE_PATH}"
      found=1
    fi
  done < <(/sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/grep -Ev '^(lo|utun|awdl|llw|bridge)' || true)
  (( found == 1 )) || warn "未自动识别局域网 IPv4；用 ipconfig getifaddr en0 手工查询。"
}

status_server() {
  if [[ ! -f "${SERVER_PID_FILE}" ]]; then
    printf '未运行：没有 PID 文件。\n'
    return 1
  fi
  server_pid="$(pid_from_file "${SERVER_PID_FILE}" 2>/dev/null || true)"
  [[ -n "${server_pid}" ]] || die "PID 文件无法解析：${SERVER_PID_FILE}；拒绝继续。"
  if ! pid_is_our_server "${server_pid}"; then
    printf '未运行：PID 文件失效（%s）。\n' "${server_pid}"
    return 1
  fi
  printf '进程运行中：PID=%s\n' "${server_pid}"
  curl --fail --silent --show-error "$(health_url)"
  printf '\n'
}

stop_server() {
  [[ -f "${SERVER_PID_FILE}" ]] || die "没有 PID 文件；server 可能未由本脚本启动。"
  server_pid="$(pid_from_file "${SERVER_PID_FILE}" 2>/dev/null || true)"
  [[ -n "${server_pid}" ]] || die "PID 文件无法解析：${SERVER_PID_FILE}；拒绝 kill。"
  pid_is_our_server "${server_pid}" || die "PID ${server_pid} 不是预期的 whisper-server；拒绝 kill。"
  kill "${server_pid}"
  for _ in $(/usr/bin/seq 1 20); do
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      rm -f "${SERVER_PID_FILE}"
      log "server 已停止。"
      return 0
    fi
    sleep 0.5
  done
  die "进程未在 10 秒内退出；请检查后决定是否手工终止，不会自动 SIGKILL。"
}

action="${1:-}"
case "${action}" in
  start)
    start_server
    ;;
  foreground)
    assert_direct_mode_available
    prepare
    log "前台启动：$(server_url)"
    exec "${server_command[@]}"
    ;;
  status)
    status_server
    ;;
  logs)
    [[ -f "${SERVER_LOG_FILE}" ]] || die "日志不存在：${SERVER_LOG_FILE}"
    exec /usr/bin/tail -n 100 -f "${SERVER_LOG_FILE}"
    ;;
  stop)
    stop_server
    ;;
  *)
    usage
    [[ -z "${action}" ]] || exit 2
    ;;
esac
