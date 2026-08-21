#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/whisper-model-location.XXXXXX")"

cleanup() {
  rm -rf -- "${TEST_HOME}"
}
trap cleanup EXIT

HOME="${TEST_HOME}" \
WHISPER_CONFIG_FILE="${PROJECT_ROOT}/.env.example" \
PROJECT_ROOT_FOR_TEST="${PROJECT_ROOT}" \
  /bin/bash <<'EOF'
set -Eeuo pipefail
source "${PROJECT_ROOT_FOR_TEST}/scripts/lib/common.sh"

expected_root="${HOME}/Library/Application Support/whisper-custom-host"
expected_model="${expected_root}/runtime/models/ggml-large-v3-turbo.bin"
expected_legacy="${PROJECT_ROOT_FOR_TEST}/models/ggml-large-v3-turbo.bin"

[[ "${WHISPER_APP_SUPPORT_ROOT}" == "${expected_root}" ]]
[[ "${MODEL_FILE}" == "${expected_model}" ]]
[[ "${GATEWAY_RUNTIME_MODEL_FILE}" == "${MODEL_FILE}" ]]
[[ "${LEGACY_MODEL_FILE}" == "${expected_legacy}" ]]
[[ "${MODEL_STATE_FILE}" == "${MODEL_DIR}/model.txt" ]]
EOF

FIXTURE="${TEST_HOME}/fixture.bin"
printf 'small deterministic model fixture\n' >"${FIXTURE}"
FIXTURE_SIZE="$(/usr/bin/stat -f '%z' "${FIXTURE}")"
FIXTURE_SHA="$(/usr/bin/shasum -a 256 "${FIXTURE}" | /usr/bin/awk '{print $1}')"

run_download_case() {
  local case_name="$1"
  local install_root="${TEST_HOME}/${case_name}/checkout"
  local app_root="${TEST_HOME}/${case_name}/Application Support/whisper-custom-host"
  local config="${TEST_HOME}/${case_name}/test.env"
  mkdir -p "${install_root}" "${app_root}" "$(dirname "${config}")"
  {
    printf 'WHISPER_INSTALL_ROOT=%q\n' "${install_root}"
    printf 'WHISPER_APP_SUPPORT_ROOT=%q\n' "${app_root}"
    printf 'WHISPER_TAG=v1.9.2\n'
    printf 'WHISPER_COMMIT=306c88f4d1286aec1bf96e544632897886af5501\n'
    printf 'WHISPER_MODEL=large-v3-turbo\n'
    printf 'WHISPER_MODEL_SHA256=%q\n' "${FIXTURE_SHA}"
    printf 'WHISPER_MODEL_SIZE_BYTES=%q\n' "${FIXTURE_SIZE}"
    printf 'WHISPER_HOST=127.0.0.1\n'
    printf 'WHISPER_PORT=49151\n'
    printf 'WHISPER_INFERENCE_PATH=/v1/audio/transcriptions\n'
    printf 'WHISPER_LANGUAGE=auto\n'
    printf 'WHISPER_THREADS=1\n'
  } >"${config}"
  CASE_INSTALL_ROOT="${install_root}"
  CASE_APP_ROOT="${app_root}"
  CASE_CONFIG="${config}"
}

# A complete, verified .part must be published only at the canonical location.
run_download_case part-publish
mkdir -p "${CASE_APP_ROOT}/runtime/models"
cp "${FIXTURE}" "${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin.part"
HOME="${TEST_HOME}" WHISPER_CONFIG_FILE="${CASE_CONFIG}" \
  "${PROJECT_ROOT}/scripts/03-download-model.sh" >/dev/null
cmp "${FIXTURE}" "${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin"
[[ ! -e "${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin.part" ]]
[[ ! -e "${CASE_INSTALL_ROOT}/models/ggml-large-v3-turbo.bin" ]]
grep -Fq "file=${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin" \
  "${CASE_APP_ROOT}/runtime/models/model.txt"

# An invalid complete .part is retained and never promoted.
run_download_case invalid-part
mkdir -p "${CASE_APP_ROOT}/runtime/models"
python3 - "${FIXTURE}" "${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin.part" <<'PY'
import pathlib
import sys

data = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
data[0] ^= 1
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
if HOME="${TEST_HOME}" WHISPER_CONFIG_FILE="${CASE_CONFIG}" \
    "${PROJECT_ROOT}/scripts/03-download-model.sh" >/dev/null 2>&1; then
  printf 'invalid complete .part was unexpectedly accepted\n' >&2
  exit 1
fi
[[ -f "${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin.part" ]]
[[ ! -e "${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin" ]]

# A verified checkout-era model is migrated once, then the legacy copy is removed.
run_download_case legacy-migration
mkdir -p "${CASE_INSTALL_ROOT}/models"
cp "${FIXTURE}" "${CASE_INSTALL_ROOT}/models/ggml-large-v3-turbo.bin"
HOME="${TEST_HOME}" WHISPER_CONFIG_FILE="${CASE_CONFIG}" \
  "${PROJECT_ROOT}/scripts/03-download-model.sh" >/dev/null
cmp "${FIXTURE}" "${CASE_APP_ROOT}/runtime/models/ggml-large-v3-turbo.bin"
[[ ! -e "${CASE_INSTALL_ROOT}/models/ggml-large-v3-turbo.bin" ]]

printf 'model-location-unit: passed\n'
