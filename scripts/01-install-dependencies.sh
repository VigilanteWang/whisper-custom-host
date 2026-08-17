#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user

install_homebrew=0
if [[ "${1:-}" == "--install-homebrew" ]]; then
  install_homebrew=1
elif [[ $# -gt 0 ]]; then
  die "未知参数：$1；可用参数只有 --install-homebrew"
fi

[[ "$(uname -s)" == "Darwin" ]] || die "只支持 macOS。"
[[ "$(uname -m)" == "arm64" ]] || die "必须从原生 arm64 终端运行。"

if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  log "请求安装 Xcode Command Line Tools。macOS 会弹出安装窗口。"
  /usr/bin/xcode-select --install || true
  die "完成图形界面安装后，再次运行本脚本。"
fi

if [[ ! -x /opt/homebrew/bin/brew ]]; then
  if (( install_homebrew == 0 )); then
    cat >&2 <<'EOF'
未安装 Apple Silicon Homebrew。

请审阅 Homebrew 官方安装脚本后，显式运行：
  ./scripts/01-install-dependencies.sh --install-homebrew

Homebrew 首次安装通常需要一次管理员授权；不要为此配置 NOPASSWD: ALL。
EOF
    exit 2
  fi

  require_command curl
  log "从 Homebrew 官方仓库运行安装器；安装器可能调用 sudo 并提示授权。"
  /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

[[ -x /opt/homebrew/bin/brew ]] || die "Homebrew 安装后仍未找到 /opt/homebrew/bin/brew。"
export PATH="/opt/homebrew/bin:${PATH}"

log "安装或确认 Git、CMake、FFmpeg"
/opt/homebrew/bin/brew install git cmake ffmpeg

log "依赖版本"
git --version
cmake --version | /usr/bin/head -n 1
ffmpeg -version | /usr/bin/head -n 1

log "依赖安装完成。此后的构建、模型下载和 server 运行都不需要 sudo。"
