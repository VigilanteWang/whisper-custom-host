#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

target="direct"
apply_changes=0

usage() {
  cat <<'EOF'
用法：
  06-firewall.sh [--target direct|on-demand] [--apply]

默认只检查 macOS Application Firewall，不修改系统。
  --target direct       仅检查/放行 build/whisper.cpp/bin/whisper-server
  --target on-demand    仅检查/放行 build/on-demand/bin/whisper-on-demand-gateway
  --apply               请求管理员授权后，只添加目标二进制并解除其拦截

脚本不会删除旧规则、关闭防火墙或扩大既有 sudo helper 权限。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { printf '错误：--target 缺少值。\n' >&2; exit 2; }
      target="$2"
      shift 2
      ;;
    --apply)
      apply_changes=1
      shift
      ;;
    -h|--help)
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

case "${target}" in
  direct)
    target_binary="${SERVER_BIN}"
    target_label="direct whisper-server"
    ;;
  on-demand)
    target_binary="${GATEWAY_BIN}"
    target_label="on-demand gateway"
    ;;
  *)
    printf '错误：--target 只能是 direct 或 on-demand：%s\n' "${target}" >&2
    exit 2
    ;;
esac

firewall_tool="/usr/libexec/ApplicationFirewall/socketfilterfw"
[[ -x "${firewall_tool}" ]] || die "找不到 macOS Application Firewall 工具。"
[[ -x "${target_binary}" ]] || die "${target_label} 二进制不存在或不可执行：${target_binary}"

"${firewall_tool}" --getglobalstate

if (( apply_changes == 0 )); then
  cat <<EOF

本脚本默认只检查，不修改系统。
目标（仅此精确二进制）：
  ${target_binary}

若防火墙已启用且局域网请求被拦截，请执行：
  $0 --target ${target} --apply
EOF
  "${firewall_tool}" --listapps | /usr/bin/grep -F -A 2 -- "${target_binary}" || true
  exit 0
fi

require_regular_user
admin_helper="${WHISPER_FIREWALL_HELPER}"
helper_status=""

if [[ -x "${admin_helper}" ]]; then
  helper_status="$(sudo -n "${admin_helper}" status 2>/dev/null || true)"
fi

# 只有 helper 的只读状态明确包含当前目标的完整路径时，才使用它。旧
# helper 指向 whisper-server 时不能被借用于 gateway，也不修改 helper 或
# 其 sudoers 配置；否则回退到两条范围精确的 socketfilterfw 命令。
if [[ -n "${helper_status}" ]] &&
   /usr/bin/grep -F -- "${target_binary}" <<<"${helper_status}" >/dev/null; then
  log "通过既有最小权限 sudo helper 配置 ${target_label} 防火墙。"
  if ! sudo -n "${admin_helper}" allow-firewall; then
    die "既有 NOPASSWD helper 调用失败；请提供 sudo -n -l 和完整错误，不要扩大到 NOPASSWD: ALL。"
  fi
else
  warn "没有匹配当前 ${target_label} 路径的免密 helper；下面两条精确命令可能要求管理员密码。"
  sudo "${firewall_tool}" --add "${target_binary}"
  sudo "${firewall_tool}" --unblockapp "${target_binary}"
fi

"${firewall_tool}" --listapps | /usr/bin/grep -F -A 2 -- "${target_binary}" || true
