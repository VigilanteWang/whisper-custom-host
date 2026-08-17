#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user
require_command curl
mkdir -p "${MODEL_DIR}" "${STATE_DIR}"

model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL}.bin"
partial_file="${MODEL_FILE}.part"

if [[ -f "${MODEL_FILE}" ]]; then
  log "模型已存在，执行完整性校验（约 1.5 GiB，可能需要一些时间）"
  assert_model_valid
  log "模型校验通过：${MODEL_FILE}"
  exit 0
fi

if [[ -f "${partial_file}" ]]; then
  partial_size="$(file_size_bytes "${partial_file}")"
  if (( partial_size > WHISPER_MODEL_SIZE_BYTES )); then
    die ".part 文件大于预期模型大小；请先人工检查并改名保留：${partial_file}"
  fi
  if [[ "${partial_size}" == "${WHISPER_MODEL_SIZE_BYTES}" ]]; then
    log "发现大小完整的 .part 文件，下载前先校验 SHA-256"
    partial_hash="$(sha256_file "${partial_file}")"
    if [[ "${partial_hash}" == "${WHISPER_MODEL_SHA256}" ]]; then
      mv "${partial_file}" "${MODEL_FILE}"
      log "现有 .part 校验通过并已转为正式模型：${MODEL_FILE}"
      exit 0
    fi
    die ".part 文件大小完整但 SHA-256 不符；请人工改名保留后重跑。"
  fi
fi

log "下载 ${WHISPER_MODEL}；支持从 .part 文件断点续传"
curl --fail --location \
  --retry 5 --retry-delay 5 --retry-all-errors \
  --continue-at - \
  --output "${partial_file}" \
  "${model_url}"

actual_size="$(file_size_bytes "${partial_file}")"
[[ "${actual_size}" == "${WHISPER_MODEL_SIZE_BYTES}" ]] || \
  die "下载大小不符：实际 ${actual_size}，预期 ${WHISPER_MODEL_SIZE_BYTES}；保留 .part 供重试。"

log "计算模型 SHA-256"
actual_hash="$(sha256_file "${partial_file}")"
[[ "${actual_hash}" == "${WHISPER_MODEL_SHA256}" ]] || \
  die "SHA-256 不符：${actual_hash}；保留 .part，不会覆盖正式模型。"

mv "${partial_file}" "${MODEL_FILE}"
cat > "${STATE_DIR}/model.txt" <<EOF
model=${WHISPER_MODEL}
file=${MODEL_FILE}
size=${actual_size}
sha256=${actual_hash}
verified_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

log "模型下载和校验完成：${MODEL_FILE}"
