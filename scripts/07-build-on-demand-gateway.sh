#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user
require_command clang++
require_command git

GATEWAY_SOURCE="${PROJECT_ROOT}/gateway/whisper_on_demand_gateway.cpp"
GATEWAY_INCLUDE_DIR="${SOURCE_DIR}/examples/server"
GATEWAY_HEADER="${GATEWAY_INCLUDE_DIR}/httplib.h"
GATEWAY_BUILD_DIR="${PROJECT_ROOT}/build/on-demand"
GATEWAY_BIN="${GATEWAY_BUILD_DIR}/bin/whisper-on-demand-gateway"
GATEWAY_STATE_FILE="${GATEWAY_BUILD_DIR}/gateway-build.txt"

[[ -f "${GATEWAY_SOURCE}" ]] || die "找不到网关源码：${GATEWAY_SOURCE}"
[[ -d "${SOURCE_DIR}/.git" ]] || die "whisper.cpp 源码不是 Git 仓库：${SOURCE_DIR}"
[[ -f "${GATEWAY_HEADER}" ]] || die "找不到固定 httplib.h：${GATEWAY_HEADER}"
[[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" == "${WHISPER_COMMIT}" ]] || \
  die "whisper.cpp commit 不符：实际 $(git -C "${SOURCE_DIR}" rev-parse HEAD)，预期 ${WHISPER_COMMIT}。"
git -C "${SOURCE_DIR}" ls-files --error-unmatch examples/server/httplib.h >/dev/null || \
  die "固定 commit 未跟踪 examples/server/httplib.h；拒绝使用未审计 header。"
git -C "${SOURCE_DIR}" diff --quiet -- examples/server/httplib.h || \
  die "httplib.h 工作树已修改；拒绝构建。"
git -C "${SOURCE_DIR}" diff --cached --quiet -- examples/server/httplib.h || \
  die "httplib.h 索引已修改；拒绝构建。"
expected_header_blob="$(git -C "${SOURCE_DIR}" rev-parse "${WHISPER_COMMIT}:examples/server/httplib.h")"
actual_header_blob="$(git -C "${SOURCE_DIR}" hash-object "${GATEWAY_HEADER}")"
[[ "${actual_header_blob}" == "${expected_header_blob}" ]] || \
  die "httplib.h blob 不等于固定 commit：实际 ${actual_header_blob}，预期 ${expected_header_blob}。"

mkdir -p "${GATEWAY_BUILD_DIR}/bin"

compiler_flags=(
  -std=c++17
  -Wall
  -Wextra
  -Wpedantic
  -Wconversion
  -Wsign-conversion
  -Wshadow
  -Werror
  -pthread
  -O2
)

temporary_bin="${GATEWAY_BIN}.tmp.$$"
temporary_state="${GATEWAY_STATE_FILE}.tmp.$$"
cleanup() {
  rm -f "${temporary_bin}"
  rm -f "${temporary_state}"
}
trap cleanup EXIT

log "核对 whisper.cpp commit=${WHISPER_COMMIT} 和 httplib.h=${GATEWAY_HEADER}"
log "使用 clang++ 构建按需网关：${GATEWAY_BIN}"
clang++ "${compiler_flags[@]}" \
  -I"${GATEWAY_INCLUDE_DIR}" \
  "${GATEWAY_SOURCE}" \
  -o "${temporary_bin}"

chmod 0755 "${temporary_bin}"
mv -f "${temporary_bin}" "${GATEWAY_BIN}"

gateway_sha256="$(sha256_file "${GATEWAY_BIN}")"
header_sha256="$(sha256_file "${GATEWAY_HEADER}")"
actual_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
cat > "${temporary_state}" <<EOF
status=success
binary=${GATEWAY_BIN}
binary_sha256=${gateway_sha256}
source=${GATEWAY_SOURCE}
httplib_header=${GATEWAY_HEADER}
httplib_header_sha256=${header_sha256}
httplib_header_blob=${actual_header_blob}
httplib_expected_header_blob=${expected_header_blob}
whisper_source=${SOURCE_DIR}
whisper_commit=${actual_commit}
architecture=$(uname -m)
compiler=$(clang++ --version | /usr/bin/head -n 1)
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
chmod 0600 "${temporary_state}"
mv -f "${temporary_state}" "${GATEWAY_STATE_FILE}"

"${GATEWAY_BIN}" --help >/dev/null
log "按需网关构建完成：${GATEWAY_BIN}"
log "二进制 SHA-256：${gateway_sha256}"
log "构建状态记录：${GATEWAY_STATE_FILE}"
