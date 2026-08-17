#!/usr/bin/env bash

set -Eeuo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

install_homebrew=0
start_server=0
audio_files=()

usage() {
  cat <<'EOF'
用法：
  ./install.sh [--install-homebrew] [--audio FILE ...] [--start]

示例（完整执行第 1-4 步）：
  ./install.sh --install-homebrew \
    --audio /path/to/chinese.m4a \
    --audio /path/to/english.m4a \
    --start

参数：
  --install-homebrew  Homebrew 缺失时运行官方安装器（可能要求管理员授权）
  --audio FILE       可重复；先经 FFmpeg 转 WAV，再用 CLI 转写
  --start            验证后以普通用户在后台启动 LAN server
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --install-homebrew)
      install_homebrew=1
      shift
      ;;
    --audio)
      [[ $# -ge 2 ]] || { printf '错误：--audio 缺少文件路径。\n' >&2; exit 2; }
      audio_files+=("$2")
      shift 2
      ;;
    --start)
      start_server=1
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

dependency_args=()
(( install_homebrew == 1 )) && dependency_args+=(--install-homebrew)
"${KIT_DIR}/scripts/01-install-dependencies.sh" "${dependency_args[@]}"
"${KIT_DIR}/scripts/00-preflight.sh"
"${KIT_DIR}/scripts/02-build-whisper.sh"
"${KIT_DIR}/scripts/03-download-model.sh"

if (( ${#audio_files[@]} > 0 )); then
  "${KIT_DIR}/scripts/04-validate-cli.sh" "${audio_files[@]}"
else
  "${KIT_DIR}/scripts/04-validate-cli.sh"
fi

if (( start_server == 1 )); then
  "${KIT_DIR}/scripts/05-server.sh" start
else
  printf '\n安装和本地验证已完成，但 server 尚未启动。\n'
  printf '启动命令：%s/scripts/05-server.sh start\n' "${KIT_DIR}"
fi
