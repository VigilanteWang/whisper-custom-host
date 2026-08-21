#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user
require_command curl
umask 077
mkdir -p "${MODEL_DIR}"
chmod 700 "${GATEWAY_SERVICE_DIR}" "${GATEWAY_RUNTIME_DIR}" "${MODEL_DIR}"

model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${WHISPER_MODEL}.bin"
partial_file="${MODEL_FILE}.part"

write_model_state() {
  local state_temp="${MODEL_STATE_FILE}.tmp.$$"
  cat > "${state_temp}" <<EOF
model=${WHISPER_MODEL}
file=${MODEL_FILE}
size=${WHISPER_MODEL_SIZE_BYTES}
sha256=${WHISPER_MODEL_SHA256}
verified_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  chmod 0600 "${state_temp}"
  mv -f "${state_temp}" "${MODEL_STATE_FILE}"
  rm -f -- "${STATE_DIR}/model.txt"
}

migrate_legacy_model() {
  [[ "${LEGACY_MODEL_FILE}" != "${MODEL_FILE}" ]] || return 0
  [[ -e "${LEGACY_MODEL_FILE}" || -L "${LEGACY_MODEL_FILE}" ]] || return 0

  local process_pid process_uid process_command migration_temp
  while read -r process_pid process_uid process_command; do
    [[ "${process_uid}" == "$(/usr/bin/id -u)" ]] || continue
    if command_has_exact_argument_pair "${process_command}" --model \
         "${LEGACY_MODEL_FILE}" ||
       command_has_exact_argument_pair "${process_command}" -m \
         "${LEGACY_MODEL_FILE}"; then
      die "PID=${process_pid} 仍在使用旧模型路径；请先停止该进程再迁移。"
    fi
  done < <(/bin/ps -axo pid=,uid=,command=)

  log "校验仓库旧模型后迁移到唯一权威位置：${MODEL_FILE}"
  assert_model_file_valid "${LEGACY_MODEL_FILE}"
  if [[ ! -f "${MODEL_FILE}" ]]; then
    migration_temp="${MODEL_FILE}.migrate.$$"
    install -m 0600 "${LEGACY_MODEL_FILE}" "${migration_temp}" || {
      rm -f -- "${migration_temp}"
      die "复制旧模型到 Application Support 失败；旧文件保持不变。"
    }
    assert_model_file_valid "${migration_temp}"
    mv -f "${migration_temp}" "${MODEL_FILE}"
  else
    assert_model_valid
  fi

  # 两边都已独立通过固定 size/SHA 校验，删除精确的旧路径，避免继续
  # 维护第二份 1.5 GiB 权威副本。需要时可由 03 脚本重新下载。
  rm -f -- "${LEGACY_MODEL_FILE}"
  log "已删除校验一致的仓库旧模型：${LEGACY_MODEL_FILE}"
}

migrate_legacy_model

if [[ -f "${MODEL_FILE}" ]]; then
  log "模型已存在，执行完整性校验（约 1.5 GiB，可能需要一些时间）"
  assert_model_valid
  write_model_state
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
      chmod 0600 "${partial_file}"
      mv "${partial_file}" "${MODEL_FILE}"
      assert_model_valid
      write_model_state
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

chmod 0600 "${partial_file}"
mv "${partial_file}" "${MODEL_FILE}"
assert_model_valid
write_model_state

log "模型下载和校验完成：${MODEL_FILE}"
