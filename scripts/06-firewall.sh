#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

firewall_tool="/usr/libexec/ApplicationFirewall/socketfilterfw"
[[ -x "${firewall_tool}" ]] || die "找不到 macOS Application Firewall 工具。"
[[ -x "${SERVER_BIN}" ]] || die "server 不存在：${SERVER_BIN}"

"${firewall_tool}" --getglobalstate

if [[ "${1:-}" != "--apply" ]]; then
  cat <<EOF

本脚本默认只检查，不修改系统。
若防火墙已启用且局域网请求被拦截，请执行：
  $0 --apply

它只会把下面这个二进制加入允许列表，不会关闭防火墙：
  ${SERVER_BIN}
EOF
  exit 0
fi

require_regular_user
admin_helper="${WHISPER_FIREWALL_HELPER}"
helper_status=""

if [[ -x "${admin_helper}" ]]; then
  helper_status="$(sudo -n "${admin_helper}" status 2>/dev/null || true)"
fi

if [[ "${helper_status}" == *"Server binary: ${SERVER_BIN}"* ]]; then
  log "通过目标机既有的最小权限 sudo helper 配置防火墙。"
  if ! sudo -n "${admin_helper}" allow-firewall; then
    die "既有 NOPASSWD helper 调用失败；请提供 sudo -n -l 和完整错误，不要扩大到 NOPASSWD: ALL。"
  fi
else
  warn "没有匹配当前 server 路径的免密 helper；下面两条精确命令可能要求管理员密码。"
  sudo "${firewall_tool}" --add "${SERVER_BIN}"
  sudo "${firewall_tool}" --unblockapp "${SERVER_BIN}"
fi
"${firewall_tool}" --listapps | /usr/bin/grep -F -A 2 -- "${SERVER_BIN}" || true
