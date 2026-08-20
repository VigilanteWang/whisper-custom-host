#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
从另一台电脑运行：
  ./verify-server.sh http://<server-host-or-ip>:8080 /绝对路径/测试音频.m4a
  ./verify-server.sh --on-demand --idle-timeout 300 \
    http://<server-host-or-ip>:8080 /绝对路径/测试音频.m4a

脚本会验证：
  1. GET /health 返回 {"status":"ok"}
  2. POST /v1/audio/transcriptions 可接收 multipart file
  3. JSON 响应含非空 text

--on-demand 额外验证：cold health、/ready、首请求计时、空闲回收和二次唤醒。
EOF
}

on_demand=0
idle_timeout=300
positional=()
while (($# > 0)); do
  case "$1" in
    --on-demand)
      on_demand=1
      shift
      ;;
    --idle-timeout)
      (($# >= 2)) || {
        printf '错误：--idle-timeout 缺少秒数。\n' >&2
        exit 2
      }
      idle_timeout="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

[[ ${#positional[@]} -eq 2 ]] || {
  usage
  exit 2
}

[[ "${idle_timeout}" =~ ^[1-9][0-9]*$ ]] || {
  printf '错误：--idle-timeout 必须是正整数秒数。\n' >&2
  exit 2
}

if ((on_demand)) && ((idle_timeout > 86400)); then
  printf '错误：--idle-timeout 不能超过 86400 秒。\n' >&2
  exit 2
fi

base_url="${positional[0]%/}"
audio_file="${positional[1]}"
health_url="${base_url}/health"
ready_url="${base_url}/ready"
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

json_field() {
  local body="$1"
  local field="$2"
  python3 - "${body}" "${field}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for key in sys.argv[2].split('.'):
    if not isinstance(value, dict):
        raise SystemExit(1)
    value = value.get(key)
if value is None:
    raise SystemExit(1)
print(value)
PY
}

now_ms() {
  python3 - <<'PY'
import time
print(time.monotonic_ns() // 1_000_000)
PY
}

if ((on_demand)); then
  backend_state="$(json_field "${health_body}" backend)" || {
    printf '错误：--on-demand 要求 /health 返回 backend 字段：' >&2
    cat "${health_body}" >&2
    printf '\n' >&2
    exit 1
  }
  [[ "${backend_state}" == "cold" ]] || {
    printf '错误：按需冷启动验收开始前 backend 应为 cold，实际为 %s。\n' "${backend_state}" >&2
    printf '请先等待已有请求完成并回收模型，再重试。\n' >&2
    exit 1
  }
  ready_code="$(curl --silent --show-error --output "${tmp_dir}/ready-before.json" --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 15 "${ready_url}")"
  [[ "${ready_code}" == "503" ]] || {
    printf '错误：cold 按需服务的 /ready 应返回 503，实际为 %s：' "${ready_code}" >&2
    cat "${tmp_dir}/ready-before.json" >&2
    printf '\n' >&2
    exit 1
  }
  printf '按需 cold/ready 通过；首请求计时中，首次加载模型可能需要较长时间\n'
fi

printf '上传并转写 %s；大模型首次请求可能需要较长时间\n' "${audio_file}"
first_started_ms="$(now_ms)"
inference_code="$(curl --silent --show-error --output "${response_body}" --write-out '%{http_code}' \
  --connect-timeout 10 --max-time 900 \
  --form "file=@${audio_file}" \
  --form 'model=whisper-1' \
  --form 'response_format=json' \
  "${inference_url}")"
first_finished_ms="$(now_ms)"

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

if ((on_demand)); then
  first_elapsed_ms=$((first_finished_ms - first_started_ms))
  first_health_code="$(curl --silent --show-error --output "${tmp_dir}/first-health.json" --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 15 "${health_url}")"
  [[ "${first_health_code}" == "200" ]] || {
    printf '错误：首请求后 /health HTTP %s。\n' "${first_health_code}" >&2
    exit 1
  }
  first_pid="$(json_field "${tmp_dir}/first-health.json" pid)" || {
    printf '错误：首请求后 /health 缺少可比较的 backend pid。\n' >&2
    exit 1
  }
  first_backend="$(json_field "${tmp_dir}/first-health.json" backend)"
  [[ "${first_backend}" == "ready" ]] || {
    printf '错误：首请求后 backend 应为 ready，实际为 %s。\n' "${first_backend}" >&2
    exit 1
  }
  printf '首请求耗时：%sms；backend pid=%s\n' "${first_elapsed_ms}" "${first_pid}"

  printf '等待按需后端空闲回收（阈值 %ss）\n' "${idle_timeout}"
  idle_deadline=$((SECONDS + idle_timeout + 30))
  idle_observed=0
  while ((SECONDS < idle_deadline)); do
    idle_code="$(curl --silent --show-error --output "${tmp_dir}/idle-health.json" --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 15 "${health_url}")"
    if [[ "${idle_code}" == "200" ]] && idle_backend="$(json_field "${tmp_dir}/idle-health.json" backend 2>/dev/null)" && [[ "${idle_backend}" == "cold" ]]; then
      idle_observed=1
      break
    fi
    sleep 1
  done
  ((idle_observed)) || {
    printf '错误：在预期时间内未观察到 backend=cold。\n' >&2
    cat "${tmp_dir}/idle-health.json" >&2 || true
    exit 1
  }
  printf '空闲回收通过；再次提交以验证二次唤醒\n'

  second_response_body="${tmp_dir}/second-transcription.json"
  second_started_ms="$(now_ms)"
  second_code="$(curl --silent --show-error --output "${second_response_body}" --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 900 \
    --form "file=@${audio_file}" --form 'model=whisper-1' \
    --form 'response_format=json' "${inference_url}")"
  second_finished_ms="$(now_ms)"
  [[ "${second_code}" == "200" ]] || {
    printf '错误：二次唤醒 inference HTTP %s：' "${second_code}" >&2
    cat "${second_response_body}" >&2
    printf '\n' >&2
    exit 1
  }
  python3 - "${second_response_body}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
text = body.get("text")
if not isinstance(text, str) or not text.strip():
    raise SystemExit(f"二次唤醒 JSON 中没有非空 text: {body!r}")
PY
  curl --silent --show-error --output "${tmp_dir}/second-health.json" \
    --connect-timeout 5 --max-time 15 "${health_url}"
  second_pid="$(json_field "${tmp_dir}/second-health.json" pid)" || {
    printf '错误：二次唤醒后 /health 缺少 backend pid。\n' >&2
    exit 1
  }
  [[ "${second_pid}" != "${first_pid}" ]] || {
    printf '错误：二次唤醒复用了旧 backend pid=%s。\n' "${second_pid}" >&2
    exit 1
  }
  second_elapsed_ms=$((second_finished_ms - second_started_ms))
  printf '二次唤醒通过：新 backend pid=%s，耗时 %sms\n' "${second_pid}" "${second_elapsed_ms}"
fi

printf '\n验收通过：%s\n' "${inference_url}"
printf '说明：multipart 中的 model=whisper-1 仅用于兼容客户端；服务端仍使用启动时固定的模型。\n'
