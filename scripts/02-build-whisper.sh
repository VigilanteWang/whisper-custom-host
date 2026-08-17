#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user
require_command git
require_command cmake

mkdir -p "$(dirname "${SOURCE_DIR}")" "${BUILD_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${RUN_DIR}"

if [[ ! -e "${SOURCE_DIR}" ]]; then
  log "克隆 whisper.cpp ${WHISPER_TAG}"
  git clone --depth 1 --branch "${WHISPER_TAG}" https://github.com/ggml-org/whisper.cpp.git "${SOURCE_DIR}"
elif [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  die "${SOURCE_DIR} 已存在但不是 Git 仓库；为保护现有文件，拒绝覆盖。"
else
  if ! git -C "${SOURCE_DIR}" diff --quiet || ! git -C "${SOURCE_DIR}" diff --cached --quiet; then
    die "${SOURCE_DIR} 有未提交修改；请先处理，脚本不会覆盖。"
  fi
  log "复用现有源码仓库并获取固定 tag"
  git -C "${SOURCE_DIR}" fetch --depth 1 origin "refs/tags/${WHISPER_TAG}:refs/tags/${WHISPER_TAG}"
  git -C "${SOURCE_DIR}" checkout --detach "${WHISPER_TAG}"
fi

actual_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
[[ "${actual_commit}" == "${WHISPER_COMMIT}" ]] || \
  die "tag 对应 commit 与配置不符：实际 ${actual_commit}，预期 ${WHISPER_COMMIT}。"

log "以 Release 配置构建，显式启用 Metal、CLI 和 server"
if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
  cached_source="$(/usr/bin/sed -n 's|^CMAKE_HOME_DIRECTORY:INTERNAL=||p' "${BUILD_DIR}/CMakeCache.txt")"
  if [[ -n "${cached_source}" && "${cached_source}" != "${SOURCE_DIR}" ]]; then
    warn "检测到迁移前的 CMake 源码路径，将重建专用构建目录：${cached_source}"
    cmake -E remove_directory "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
  fi
fi

cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_METAL=ON \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_SERVER=ON \
  -DWHISPER_BUILD_TESTS=OFF

parallel_jobs="$(/usr/sbin/sysctl -n hw.logicalcpu)"
cmake --build "${BUILD_DIR}" --config Release --parallel "${parallel_jobs}"

[[ -x "${CLI_BIN}" ]] || die "构建后未找到 ${CLI_BIN}"
[[ -x "${SERVER_BIN}" ]] || die "构建后未找到 ${SERVER_BIN}"
/usr/bin/grep -q '^GGML_METAL:BOOL=ON$' "${BUILD_DIR}/CMakeCache.txt" || \
  die "CMakeCache 未显示 GGML_METAL=ON。"

cat > "${STATE_DIR}/build.txt" <<EOF
tag=${WHISPER_TAG}
commit=${actual_commit}
architecture=$(uname -m)
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
metal=ON
EOF

log "构建完成：${SERVER_BIN}"
