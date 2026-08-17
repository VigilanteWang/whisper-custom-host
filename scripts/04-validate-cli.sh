#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_regular_user
require_command ffmpeg
[[ -x "${CLI_BIN}" ]] || die "CLI 不存在：${CLI_BIN}；先运行 02-build-whisper.sh。"
assert_model_valid

audio_files=("$@")
if (( ${#audio_files[@]} == 0 )); then
  bundled_sample="${SOURCE_DIR}/samples/jfk.wav"
  [[ -f "${bundled_sample}" ]] || die "未传音频，且找不到仓库自带样本：${bundled_sample}"
  warn "未传入真实中英文录音，仅使用英文 JFK 样本做冒烟测试；这不算完成中英文验收。"
  audio_files=("${bundled_sample}")
fi

mkdir -p "${LOG_DIR}/cli-validation"

for audio_file in "${audio_files[@]}"; do
  [[ -f "${audio_file}" ]] || die "音频文件不存在：${audio_file}"

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/whisper-cli.XXXXXX")"
  wav_file="${work_dir}/input.wav"
  base_name="$(basename "${audio_file}")"
  safe_name="$(printf '%s' "${base_name}" | /usr/bin/tr -cs '[:alnum:]._-' '_')"
  output_prefix="${LOG_DIR}/cli-validation/${safe_name}-$(date '+%Y%m%d-%H%M%S')"
  runtime_log="${output_prefix}.runtime.log"

  cleanup() {
    rm -rf "${work_dir}"
  }
  trap 'cleanup' EXIT

  log "FFmpeg 转换为 whisper-cli 所需的 16 kHz、单声道、16-bit WAV：${audio_file}"
  ffmpeg -hide_banner -loglevel error -y -i "${audio_file}" \
    -ar 16000 -ac 1 -c:a pcm_s16le "${wav_file}"

  log "运行本地转写；首次加载大模型可能较慢"
  "${CLI_BIN}" \
    --model "${MODEL_FILE}" \
    --file "${wav_file}" \
    --language auto \
    --output-txt \
    --output-file "${output_prefix}" \
    2> >(tee "${runtime_log}" >&2)

  transcript_file="${output_prefix}.txt"
  [[ -s "${transcript_file}" ]] || die "CLI 未生成非空转写：${transcript_file}"

  if /usr/bin/grep -Eiq 'metal|gpu' "${runtime_log}"; then
    log "运行日志中检测到 Metal/GPU 后端信息。"
  else
    warn "运行日志中未检测到 Metal/GPU 字样；请人工查看 ${runtime_log}。"
  fi

  printf '\n===== %s =====\n' "${audio_file}"
  /bin/cat "${transcript_file}"
  printf '\n结果文件：%s\n\n' "${transcript_file}"

  trap - EXIT
  cleanup
done

log "CLI、模型和 FFmpeg 验证完成。请人工确认中英文内容是否合理。"
