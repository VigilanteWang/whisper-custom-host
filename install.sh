#!/usr/bin/env bash

set -Eeuo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

install_homebrew=0
start_server=0
on_demand=0
audio_files=()

usage() {
  cat <<'EOF'
用法：
  ./install.sh [--install-homebrew] [--audio FILE ...] [--on-demand] [--start]

示例（完整执行第 1-4 步）：
  ./install.sh --install-homebrew \
    --audio /path/to/chinese.m4a \
    --audio /path/to/english.m4a \
    --start

参数：
  --install-homebrew  Homebrew 缺失时运行官方安装器（可能要求管理员授权）
  --audio FILE       可重复；先经 FFmpeg 转 WAV，再用 CLI 转写
  --on-demand        构建并安装常驻轻量网关；模型后端按请求启动
  --start            验证后启动所选模式；--on-demand --start 启动 LaunchAgent
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
    --on-demand)
      on_demand=1
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

if (( on_demand == 1 )); then
  # 网关构建脚本由按需网关子任务提供。显式检查可把“代码已安装但构建
  # 入口缺失”与 whisper.cpp 本身的构建错误区分开，且不影响旧 direct
  # 路径的默认行为。
  [[ -f "${KIT_DIR}/scripts/07-build-on-demand-gateway.sh" ]] || {
    printf '错误：找不到按需网关构建脚本：%s\n' \
      "${KIT_DIR}/scripts/07-build-on-demand-gateway.sh" >&2
    exit 1
  }
  /bin/bash "${KIT_DIR}/scripts/07-build-on-demand-gateway.sh"
  "${KIT_DIR}/scripts/08-on-demand-service.sh" install
  if (( start_server == 1 )); then
    "${KIT_DIR}/scripts/08-on-demand-service.sh" start
  else
    printf '\n按需网关已构建并安装 LaunchAgent，但尚未启动。\n'
    printf '启动命令：%s/scripts/08-on-demand-service.sh start\n' "${KIT_DIR}"
  fi
elif (( start_server == 1 )); then
  "${KIT_DIR}/scripts/05-server.sh" start
else
  printf '\n安装和本地验证已完成，但 server 尚未启动。\n'
  printf '启动命令：%s/scripts/05-server.sh start\n' "${KIT_DIR}"
fi
