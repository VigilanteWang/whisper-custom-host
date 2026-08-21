#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
TEST_ROOT="$(/bin/realpath "$(mktemp -d "${TMPDIR:-/tmp}/whisper-purge-unit.XXXXXX")")"

cleanup() {
  /bin/rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

MODEL_BYTES='purge model fixture\n'
MODEL_SIZE="${#MODEL_BYTES}"
MODEL_SHA="$(printf '%s' "${MODEL_BYTES}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

write_config() {
  local case_dir="$1" app_root="$2" config
  config="${case_dir}/test.env"
  mkdir -p "${case_dir}/checkout" "$(dirname "${config}")"
  {
    printf 'WHISPER_INSTALL_ROOT=%q\n' "${case_dir}/checkout"
    printf 'WHISPER_APP_SUPPORT_ROOT=%q\n' "${app_root}"
    printf 'WHISPER_TAG=v1.9.2\n'
    printf 'WHISPER_COMMIT=306c88f4d1286aec1bf96e544632897886af5501\n'
    printf 'WHISPER_MODEL=purge-fixture\n'
    printf 'WHISPER_MODEL_SHA256=%q\n' "${MODEL_SHA}"
    printf 'WHISPER_MODEL_SIZE_BYTES=%q\n' "${MODEL_SIZE}"
    printf 'WHISPER_HOST=127.0.0.1\nWHISPER_PORT=49151\n'
    printf 'WHISPER_INFERENCE_PATH=/v1/audio/transcriptions\n'
    printf 'WHISPER_LANGUAGE=auto\nWHISPER_THREADS=1\n'
  } >"${config}"
  printf '%s' "${config}"
}

run_purge() {
  local config="$1"
  HOME="${TEST_ROOT}/home" WHISPER_CONFIG_FILE="${config}" \
    PROJECT_ROOT_FOR_TEST="${PROJECT_ROOT}" /bin/bash <<'EOF'
set -Eeuo pipefail
source "${PROJECT_ROOT_FOR_TEST}/scripts/lib/common.sh"
purge_application_support
EOF
}

run_failure_without_deletion() {
  local config="$1" marker="$2"
  if HOME="${TEST_ROOT}/home" WHISPER_CONFIG_FILE="${config}" \
      PROJECT_ROOT_FOR_TEST="${PROJECT_ROOT}" /bin/bash <<'EOF'
set -Eeuo pipefail
source "${PROJECT_ROOT_FOR_TEST}/scripts/lib/common.sh"
purge_application_support
EOF
  then
    printf 'purge unexpectedly succeeded\n' >&2
    exit 1
  fi
  [[ -f "${marker}" ]] || {
    printf 'purge removed data after a rejected preflight: %s\n' "${marker}" >&2
    exit 1
  }
}

# A valid model survives byte-for-byte with its owner/mode/time unchanged;
# deployment binaries, runtime state, hidden files, and unknown sidecars do
# not survive.
CASE_DIR="${TEST_ROOT}/valid"
APP_ROOT="${CASE_DIR}/Application Support/whisper-custom-host"
CONFIG="$(write_config "${CASE_DIR}" "${APP_ROOT}")"
MODEL_FILE_FIXTURE="${APP_ROOT}/runtime/models/ggml-purge-fixture.bin"
mkdir -p "$(dirname "${MODEL_FILE_FIXTURE}")" \
  "${APP_ROOT}/bin" "${APP_ROOT}/runtime/run/uploads" "${APP_ROOT}/runtime/log"
printf '%s' "${MODEL_BYTES}" >"${MODEL_FILE_FIXTURE}"
chmod 0600 "${MODEL_FILE_FIXTURE}"
MODEL_STAT_BEFORE="$(/usr/bin/stat -f '%u:%Lp:%m:%z' "${MODEL_FILE_FIXTURE}")"
MODEL_SHA_BEFORE="$(/usr/bin/shasum -a 256 "${MODEL_FILE_FIXTURE}" | /usr/bin/awk '{print $1}')"
for path in \
  "${APP_ROOT}/bin/whisper-on-demand-gateway" \
  "${APP_ROOT}/bin/whisper-server" \
  "${APP_ROOT}/bin/libwhisper.dylib" \
  "${APP_ROOT}/bin/whisper-on-demand-gateway.previous" \
  "${APP_ROOT}/bin/.gateway.temporary" \
  "${APP_ROOT}/runtime/run/uploads/audio.part" \
  "${APP_ROOT}/runtime/run/whisper-on-demand-gateway.pid" \
  "${APP_ROOT}/runtime/log/whisper-on-demand-gateway.log" \
  "${APP_ROOT}/runtime/models/model.txt" \
  "${APP_ROOT}/runtime/models/ggml-purge-fixture.bin.part" \
  "${APP_ROOT}/runtime/models/ggml-purge-fixture.bin.migrate.123" \
  "${APP_ROOT}/.unknown-sidecar"; do
  printf 'remove me\n' >"${path}"
done
mkdir -p "${APP_ROOT}/candidate-bin.ABC" "${APP_ROOT}/runtime/whisper.cpp/.git"
printf 'remove me\n' >"${APP_ROOT}/candidate-bin.ABC/whisper-server"
printf 'remove me\n' >"${APP_ROOT}/runtime/whisper.cpp/httplib.h"
printf 'remove me\n' >"${APP_ROOT}/runtime/whisper.cpp/.git/HEAD"
run_purge "${CONFIG}"
[[ -f "${MODEL_FILE_FIXTURE}" ]]
[[ "$(/usr/bin/shasum -a 256 "${MODEL_FILE_FIXTURE}" | /usr/bin/awk '{print $1}')" == "${MODEL_SHA_BEFORE}" ]]
[[ "$(/usr/bin/stat -f '%u:%Lp:%m:%z' "${MODEL_FILE_FIXTURE}")" == "${MODEL_STAT_BEFORE}" ]]
[[ -z "$(/usr/bin/find "${APP_ROOT}" -mindepth 1 \
  ! -path "${MODEL_FILE_FIXTURE}" \
  ! -path "${APP_ROOT}/runtime" \
  ! -path "${APP_ROOT}/runtime/models" -print)" ]]

# No authoritative model is also a safe purge precondition (the caller may
# be cleaning a partially-installed runtime).
CASE_DIR="${TEST_ROOT}/absent"
APP_ROOT="${CASE_DIR}/Application Support/whisper-custom-host"
CONFIG="$(write_config "${CASE_DIR}" "${APP_ROOT}")"
mkdir -p "${APP_ROOT}/runtime/models" "${APP_ROOT}/bin"
printf 'remove me\n' >"${APP_ROOT}/bin/old-gateway"
run_purge "${CONFIG}"
[[ -d "${APP_ROOT}" ]]
[[ -z "$(/usr/bin/find "${APP_ROOT}" -mindepth 1 -print)" ]]

# A corrupt model and a model symlink both abort before any sibling is
# removed.  An absent model is intentionally accepted by purge (uninstall
# may be cleaning a partially-installed runtime).
for failure in corrupt symlink; do
  CASE_DIR="${TEST_ROOT}/${failure}"
  APP_ROOT="${CASE_DIR}/Application Support/whisper-custom-host"
  CONFIG="$(write_config "${CASE_DIR}" "${APP_ROOT}")"
  MODEL_FILE_FIXTURE="${APP_ROOT}/runtime/models/ggml-purge-fixture.bin"
  mkdir -p "$(dirname "${MODEL_FILE_FIXTURE}")"
  if [[ "${failure}" == "corrupt" ]]; then
    printf 'bad model\n' >"${MODEL_FILE_FIXTURE}"
  else
    printf '%s' "${MODEL_BYTES}" >"${CASE_DIR}/external-model.bin"
    ln -s "${CASE_DIR}/external-model.bin" "${MODEL_FILE_FIXTURE}"
  fi
  marker="${APP_ROOT}/keep-me"
  printf 'must remain\n' >"${marker}"
  run_failure_without_deletion "${CONFIG}" "${marker}"
done

CASE_DIR="${TEST_ROOT}/dangerous"
APP_ROOT="${TEST_ROOT}/home"
CONFIG="$(write_config "${CASE_DIR}" "${APP_ROOT}")"
mkdir -p "${APP_ROOT}"
marker="${APP_ROOT}/keep-me"
printf 'must remain\n' >"${marker}"
run_failure_without_deletion "${CONFIG}" "${marker}"

# The purge root itself being a symlink is rejected before traversal.  The
# marker under the real target must survive.
CASE_DIR="${TEST_ROOT}/root-self-symlink"
TARGET_ROOT="${CASE_DIR}/real/whisper-custom-host"
APP_ROOT="${CASE_DIR}/root/whisper-custom-host"
CONFIG="$(write_config "${CASE_DIR}" "${APP_ROOT}")"
mkdir -p "${TARGET_ROOT}" "${CASE_DIR}/root"
ln -s "${TARGET_ROOT}" "${APP_ROOT}"
marker="${TARGET_ROOT}/keep-me"
printf 'must remain\n' >"${marker}"
run_failure_without_deletion "${CONFIG}" "${marker}"

# Any ancestor component being a symlink is also rejected before traversal.
CASE_DIR="${TEST_ROOT}/ancestor-symlink"
TARGET_ROOT="${CASE_DIR}/real/Application Support/whisper-custom-host"
APP_ROOT="${CASE_DIR}/link-parent/Application Support/whisper-custom-host"
CONFIG="$(write_config "${CASE_DIR}" "${APP_ROOT}")"
mkdir -p "${TARGET_ROOT}"
ln -s "${CASE_DIR}/real" "${CASE_DIR}/link-parent"
marker="${TARGET_ROOT}/keep-me"
printf 'must remain\n' >"${marker}"
run_failure_without_deletion "${CONFIG}" "${marker}"

# Parameter parsing must reject duplicate/misplaced/unknown purge flags before
# reaching service prerequisites.  These 08 commands do not touch launchd.
expect_exit() {
  local expected="$1" status
  shift
  if "$@" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "${status}" -eq "${expected}" ]] || {
    printf 'unexpected exit status %s (expected %s): %s\n' \
      "${status}" "${expected}" "$*" >&2
    exit 1
  }
}

for action in install start uninstall; do
  expect_exit 2 "${PROJECT_ROOT}/scripts/08-on-demand-service.sh" \
    "${action}" --purge --purge
  expect_exit 2 "${PROJECT_ROOT}/scripts/08-on-demand-service.sh" \
    "${action}" --unsupported
  expect_exit 2 "${PROJECT_ROOT}/scripts/08-on-demand-service.sh" \
    "${action}" --purge --unsupported
done
for action in stop status foreground logs; do
  expect_exit 2 "${PROJECT_ROOT}/scripts/08-on-demand-service.sh" \
    "${action}" --purge
done
expect_exit 2 "${PROJECT_ROOT}/install.sh" --purge
expect_exit 2 "${PROJECT_ROOT}/install.sh" --purge --purge
expect_exit 2 "${PROJECT_ROOT}/install.sh" --on-demand --purge --purge
expect_exit 2 "${PROJECT_ROOT}/install.sh" --unsupported
expect_exit 0 "${PROJECT_ROOT}/install.sh" --help

# Exercise successful argument parsing without touching this checkout's build,
# LaunchAgent, or online service.  A temporary install copy uses stubs for all
# numbered scripts and records the exact 08 arguments it receives.
CLI_FIXTURE="${TEST_ROOT}/install-cli"
CLI_SCRIPTS="${CLI_FIXTURE}/scripts"
CLI_CALL_LOG="${CLI_FIXTURE}/calls.log"
mkdir -p "${CLI_SCRIPTS}"
cp "${PROJECT_ROOT}/install.sh" "${CLI_FIXTURE}/install.sh"
chmod +x "${CLI_FIXTURE}/install.sh"
for script_name in \
  00-preflight.sh 01-install-dependencies.sh 02-build-whisper.sh \
  03-download-model.sh 04-validate-cli.sh 05-server.sh \
  07-build-on-demand-gateway.sh 08-on-demand-service.sh; do
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    # The following three lines intentionally emit shell expressions for the
    # generated stub; they must expand when the stub, not this test, runs.
    # shellcheck disable=SC2016
    printf 'printf "%%s" "$(basename "$0")" >> "${CLI_CALL_LOG}"\n'
    # shellcheck disable=SC2016
    printf 'for arg in "$@"; do printf " %%s" "$arg" >> "${CLI_CALL_LOG}"; done\n'
    # shellcheck disable=SC2016
    printf 'printf "\\n" >> "${CLI_CALL_LOG}"\n'
  } >"${CLI_SCRIPTS}/${script_name}"
  chmod +x "${CLI_SCRIPTS}/${script_name}"
done

: >"${CLI_CALL_LOG}"
CLI_CALL_LOG="${CLI_CALL_LOG}" "${CLI_FIXTURE}/install.sh" --on-demand
grep -Fqx '08-on-demand-service.sh install' "${CLI_CALL_LOG}"
if grep -Fq '08-on-demand-service.sh install --purge' "${CLI_CALL_LOG}"; then
  exit 1
fi
if grep -Fq '08-on-demand-service.sh start' "${CLI_CALL_LOG}"; then
  exit 1
fi

: >"${CLI_CALL_LOG}"
CLI_CALL_LOG="${CLI_CALL_LOG}" "${CLI_FIXTURE}/install.sh" \
  --on-demand --purge --start
grep -Fqx '08-on-demand-service.sh install --purge' "${CLI_CALL_LOG}"
grep -Fqx '08-on-demand-service.sh start' "${CLI_CALL_LOG}"
if grep -Fq '08-on-demand-service.sh start --purge' "${CLI_CALL_LOG}"; then
  exit 1
fi

printf 'on-demand-purge-unit: passed\n'
