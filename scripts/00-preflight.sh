#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user

failures=0

check_ok() {
  printf '  [OK] %s\n' "$1"
}

check_fail() {
  printf '  [失败] %s\n' "$1" >&2
  failures=$((failures + 1))
}

log "检查主机、工具链和安装目标"

[[ "$(uname -s)" == "Darwin" ]] && check_ok "操作系统是 macOS" || check_fail "只支持 macOS"
[[ "$(uname -m)" == "arm64" ]] && check_ok "当前 shell 是原生 arm64" || check_fail "当前 shell 不是 arm64；退出 Rosetta/x86 终端后重试"

translated="$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)"
[[ "${translated}" != "1" ]] && check_ok "进程未运行在 Rosetta 下" || check_fail "进程正在 Rosetta 下运行"

if /usr/bin/xcode-select -p >/dev/null 2>&1; then
  check_ok "Xcode Command Line Tools 已安装：$(/usr/bin/xcode-select -p)"
else
  check_fail "Xcode Command Line Tools 未安装；执行 xcode-select --install，完成后重跑"
fi

if [[ -x /opt/homebrew/bin/brew ]]; then
  check_ok "找到 Apple Silicon Homebrew：$(/opt/homebrew/bin/brew --prefix)"
else
  check_fail "未找到 /opt/homebrew/bin/brew；运行 01-install-dependencies.sh --install-homebrew"
fi

for command_name in git cmake ffmpeg curl; do
  if command -v "${command_name}" >/dev/null 2>&1; then
    check_ok "${command_name}: $(command -v "${command_name}")"
  else
    check_fail "缺少 ${command_name}；运行 01-install-dependencies.sh"
  fi
done

available_kib="$(/bin/df -Pk "${HOME}" | /usr/bin/awk 'NR == 2 {print $4}')"
required_kib=$((6 * 1024 * 1024))
if [[ "${available_kib}" =~ ^[0-9]+$ ]] && (( available_kib >= required_kib )); then
  check_ok "用户卷可用空间不少于 6 GiB"
else
  check_fail "用户卷可用空间不足 6 GiB"
fi

if [[ "${WHISPER_PORT}" =~ ^[0-9]+$ ]] && (( WHISPER_PORT >= 1 && WHISPER_PORT <= 65535 )); then
  check_ok "服务端口有效：${WHISPER_PORT}"
else
  check_fail "服务端口无效：${WHISPER_PORT}"
fi

if (( failures > 0 )); then
  die "预检发现 ${failures} 个问题。修复后重跑本脚本。"
fi

log "预检通过。安装目录：${WHISPER_INSTALL_ROOT}"
