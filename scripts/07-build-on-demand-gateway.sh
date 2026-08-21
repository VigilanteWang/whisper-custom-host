#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user
require_command cmake
require_command ctest
require_command clang++
require_command git

GATEWAY_SOURCE_DIR="${PROJECT_ROOT}/gateway"
GATEWAY_CMAKE_FILE="${GATEWAY_SOURCE_DIR}/CMakeLists.txt"
GATEWAY_INCLUDE_DIR="${SOURCE_DIR}/examples/server"
GATEWAY_HEADER="${GATEWAY_INCLUDE_DIR}/httplib.h"
GATEWAY_BUILD_DIR="${ON_DEMAND_BUILD_DIR}"
GATEWAY_BIN="${GATEWAY_BUILD_DIR}/bin/whisper-on-demand-gateway"
GATEWAY_STATE_FILE="${GATEWAY_BUILD_DIR}/gateway-build.txt"

[[ -f "${GATEWAY_CMAKE_FILE}" ]] || die "找不到网关 CMake 工程：${GATEWAY_CMAKE_FILE}"
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

mkdir -p "${GATEWAY_BUILD_DIR}" "${GATEWAY_BUILD_DIR}/bin"
candidate_root="$(mktemp -d "${GATEWAY_BUILD_DIR}/candidate.XXXXXX")"
release_build="${candidate_root}/release"
sanitizer_build="${candidate_root}/sanitizers"
temporary_bin="${GATEWAY_BIN}.tmp.$$"
temporary_state="${GATEWAY_STATE_FILE}.tmp.$$"
rollback_bin="${GATEWAY_BIN}.rollback.$$"
rollback_state="${GATEWAY_STATE_FILE}.rollback.$$"

cleanup() {
  rm -f -- "${temporary_bin}" "${temporary_state}" \
    "${rollback_bin}" "${rollback_state}"
  rm -rf -- "${candidate_root}"
}
trap cleanup EXIT

configure_build() {
  local build_dir="$1"
  local sanitizers="$2"
  cmake -S "${GATEWAY_SOURCE_DIR}" -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
    -DGATEWAY_HTTPLIB_INCLUDE="${GATEWAY_INCLUDE_DIR}" \
    -DGATEWAY_ENABLE_SANITIZERS="${sanitizers}" \
    -DBUILD_TESTING=ON
  cmake --build "${build_dir}" --parallel
  local test_count
  test_count="$(ctest --test-dir "${build_dir}" -N | awk '/Total Tests:/ {print $3}')"
  [[ "${test_count}" == "3" ]] || \
    die "CTest 注册数量不完整：实际 ${test_count:-0}，预期 3。"
}

log "核对 whisper.cpp commit=${WHISPER_COMMIT} 和 httplib.h=${GATEWAY_HEADER}"
"${PROJECT_ROOT}/tests/model-location-unit.sh"
log "配置并构建 release 候选产物（不会覆盖当前在线二进制）"
configure_build "${release_build}" OFF
ctest --test-dir "${release_build}" --output-on-failure
"${release_build}/bin/whisper-on-demand-gateway" --help >/dev/null
env -u ON_DEMAND_TEST_CASE "${PROJECT_ROOT}/tests/on-demand-integration.sh" \
  --gateway "${release_build}/bin/whisper-on-demand-gateway"

log "配置并构建 ASan/UBSan 候选产物"
configure_build "${sanitizer_build}" ON
ASAN_OPTIONS="detect_leaks=0:halt_on_error=1" \
UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
  ctest --test-dir "${sanitizer_build}" --output-on-failure
ASAN_OPTIONS="detect_leaks=0:halt_on_error=1" \
UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
  env -u ON_DEMAND_TEST_CASE "${PROJECT_ROOT}/tests/on-demand-integration.sh" \
    --gateway "${sanitizer_build}/bin/whisper-on-demand-gateway"

candidate_bin="${release_build}/bin/whisper-on-demand-gateway"
[[ -x "${candidate_bin}" ]] || die "候选网关产物不存在：${candidate_bin}"
install -m 0755 "${candidate_bin}" "${temporary_bin}"

gateway_sha256="$(sha256_file "${temporary_bin}")"
header_sha256="$(sha256_file "${GATEWAY_HEADER}")"
actual_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
cat > "${temporary_state}" <<EOF
status=success
binary=${GATEWAY_BIN}
binary_sha256=${gateway_sha256}
source=${GATEWAY_SOURCE_DIR}
httplib_header=${GATEWAY_HEADER}
httplib_header_sha256=${header_sha256}
httplib_header_blob=${actual_header_blob}
httplib_expected_header_blob=${expected_header_blob}
whisper_source=${SOURCE_DIR}
whisper_commit=${actual_commit}
architecture=$(uname -m)
compiler=$(clang++ --version | /usr/bin/head -n 1)
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
tests=model-location-unit,ctest,help,15-loopback-integration,asan-ubsan-ctest,asan-ubsan-integration
EOF
chmod 0600 "${temporary_state}"

# Publication happens only after every release and sanitizer gate succeeds.
# Each file replacement is an atomic same-directory rename.  Keep private
# rollback copies until both replacements succeed so a metadata rename failure
# cannot leave a new binary paired with stale build state.
had_previous_bin=0
had_previous_state=0
if [[ -f "${GATEWAY_BIN}" ]]; then
  cp -p "${GATEWAY_BIN}" "${rollback_bin}"
  had_previous_bin=1
fi
if [[ -f "${GATEWAY_STATE_FILE}" ]]; then
  cp -p "${GATEWAY_STATE_FILE}" "${rollback_state}"
  had_previous_state=1
fi
if ! mv -f "${temporary_bin}" "${GATEWAY_BIN}"; then
  die "候选二进制发布失败；旧产物未被替换。"
fi
if ! mv -f "${temporary_state}" "${GATEWAY_STATE_FILE}"; then
  if (( had_previous_bin == 1 )); then
    mv -f "${rollback_bin}" "${GATEWAY_BIN}" || \
      die "构建状态发布失败，且旧二进制自动恢复失败：${rollback_bin}"
  else
    rm -f -- "${GATEWAY_BIN}"
  fi
  die "构建状态发布失败；已恢复发布前二进制。"
fi
if (( had_previous_bin == 1 )); then
  mv -f "${rollback_bin}" "${GATEWAY_BIN}.previous"
fi
if (( had_previous_state == 1 )); then
  mv -f "${rollback_state}" "${GATEWAY_STATE_FILE}.previous"
fi

log "按需网关候选产物已全量验证并原子发布：${GATEWAY_BIN}"
log "二进制 SHA-256：${gateway_sha256}"
log "构建状态记录：${GATEWAY_STATE_FILE}"
