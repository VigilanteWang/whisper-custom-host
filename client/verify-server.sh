#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
从另一台电脑运行：
  ./verify-server.sh http://<server-host-or-ip>:8080 /绝对路径/测试音频.m4a

脚本会验证：
  1. GET /health 返回 {"status":"ok"}
  2. POST /v1/audio/transcriptions 可接收 multipart file
  3. JSON 响应含非空 text
EOF
}

[[ $# -eq 2 ]] || {
  usage
  exit 2
}

base_url="${1%/}"
audio_file="$2"
health_url="${base_url}/health"
inference_url="${base_url}/v1/audio/transcriptions"

[[ -f "${audio_file}" ]] || {
  printf '错误：音频不存在：%s\n' "${audio_file}" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf '错误：缺少 curl。\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf '错误：缺少 python3（只用于严格解析 JSON）。\n' >&2
  exit 1
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/whisper-remote.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT
health_body="${tmp_dir}/health.json"
response_body="${tmp_dir}/transcription.json"

printf '检查 %s\n' "${health_url}"
health_code="$(curl --silent --show-error --output "${health_body}" --write-out '%{http_code}' \
  --connect-timeout 5 --max-time 15 "${health_url}")"
[[ "${health_code}" == "200" ]] || {
  printf '错误：health HTTP %s：' "${health_code}" >&2
  cat "${health_body}" >&2
  printf '\n' >&2
  exit 1
}

python3 - "${health_body}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    body = json.load(f)
if body.get("status") != "ok":
    raise SystemExit(f"health 内容不符合预期: {body!r}")
print("health 通过:", body)
PY

printf '上传并转写 %s；大模型首次请求可能需要较长时间\n' "${audio_file}"
inference_code="$(curl --silent --show-error --output "${response_body}" --write-out '%{http_code}' \
  --connect-timeout 10 --max-time 900 \
  --form "file=@${audio_file}" \
  --form 'model=whisper-1' \
  --form 'response_format=json' \
  "${inference_url}")"

[[ "${inference_code}" == "200" ]] || {
  printf '错误：inference HTTP %s：' "${inference_code}" >&2
  cat "${response_body}" >&2
  printf '\n' >&2
  exit 1
}

python3 - "${response_body}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    body = json.load(f)
text = body.get("text")
if not isinstance(text, str) or not text.strip():
    raise SystemExit(f"JSON 中没有非空 text: {body!r}")
print("远程转写通过，text：")
print(text.strip())
PY

printf '\n验收通过：%s\n' "${inference_url}"
printf '说明：multipart 中的 model=whisper-1 仅用于兼容客户端；服务端仍使用启动时固定的模型。\n'
