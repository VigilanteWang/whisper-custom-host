#!/usr/bin/env bash

# End-to-end checks for the on-demand gateway. Every case uses loopback and
# ports selected by the kernel; this script must never start a service on the
# deployment ports (8080/18080) and never talks to launchd.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
GATEWAY_BIN="${ON_DEMAND_GATEWAY_BIN:-${PROJECT_ROOT}/build/on-demand/bin/whisper-on-demand-gateway}"
CXX="${CXX:-clang++}"
KEEP_TEMP=0
COMPILE_ONLY=0
RUN_CASE_COUNT=0

usage() {
  cat <<'EOF'
用法：
  tests/on-demand-integration.sh [--gateway PATH] [--keep-temp] [--compile-only]

说明：
  编译两个 mock fixture，并在临时 loopback 端口上测试网关。
  网关必须读取计划中的 WHISPER_* 环境变量；测试会把后端可执行文件
  注入为 fixture，不会触碰正式 8080/18080 或 LaunchAgent。
  可用 ON_DEMAND_TEST_CASE=chunked-epilogue-limit 等只运行一个 case。
EOF
}

while (($# > 0)); do
  case "$1" in
    --gateway)
      (($# >= 2)) || { printf '错误：--gateway 缺少路径。\n' >&2; exit 2; }
      GATEWAY_BIN="$2"
      shift 2
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    --compile-only)
      COMPILE_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '错误：未知参数：%s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '错误：缺少命令：%s\n' "$1" >&2
    exit 2
  }
}

require_command curl
require_command python3
require_command "$CXX"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/whisper-on-demand.XXXXXX")"
TMP_ROOT="$(cd -- "${TMP_ROOT}" && pwd -P)"
TEST_MODEL_FILE="${TMP_ROOT}/mock-model.bin"
MOCK_BIN="${TMP_ROOT}/mock-whisper-server"
MOCK_BIN_REAL="${MOCK_BIN}"
RAW_MOCK_BIN="${TMP_ROOT}/mock-raw-whisper-server"
MOCK_INCLUDE="${PROJECT_ROOT}/third_party/whisper.cpp/examples/server"
BACKEND_BIN="${MOCK_BIN}"
BACKEND_BIN_REAL="${MOCK_BIN}"
CAPTURE_BODY_FILE=""
CAPTURE_HEADERS_FILE=""

cleanup() {
  set +e
  if [[ -n "${GW_PID:-}" ]]; then
    kill -TERM "${GW_PID}" 2>/dev/null || true
    wait "${GW_PID}" 2>/dev/null || true
  fi
  if [[ -n "${FOREIGN_PID:-}" ]]; then
    kill -TERM "${FOREIGN_PID}" 2>/dev/null || true
    wait "${FOREIGN_PID}" 2>/dev/null || true
  fi
  # If a gateway exits before it can reap its child, clean only fixture
  # processes created in this mktemp directory.  Never use a broad pkill.
  for binary in "${MOCK_BIN_REAL}" "${BACKEND_BIN_REAL}"; do
    [[ -n "${binary}" ]] || continue
    for pid in $(ps -axo pid=,command= | awk -v binary="${binary}" '$2 == binary {print $1}'); do
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL "$pid" 2>/dev/null || true
    done
  done
  if ((KEEP_TEMP)); then
    printf '临时目录已保留：%s\n' "${TMP_ROOT}"
  else
    rm -rf -- "${TMP_ROOT}"
  fi
}
trap cleanup EXIT INT TERM

printf '编译 mock whisper-server：%s\n' "${MOCK_BIN}"
"${CXX}" -std=c++17 -Wall -Wextra -Wpedantic -Werror -pthread \
  -I "${MOCK_INCLUDE}" "${SCRIPT_DIR}/mock-whisper-server.cc" \
  -o "${MOCK_BIN}"
printf '编译 raw multipart mock whisper-server：%s\n' "${RAW_MOCK_BIN}"
"${CXX}" -std=c++17 -Wall -Wextra -Wpedantic -Werror -pthread \
  "${SCRIPT_DIR}/mock-raw-whisper-server.cc" \
  -o "${RAW_MOCK_BIN}"

if ((COMPILE_ONLY)); then
  printf 'fixture 编译通过。\n'
  exit 0
fi

[[ -x "${GATEWAY_BIN}" ]] || {
  printf '错误：找不到可执行网关：%s\n' "${GATEWAY_BIN}" >&2
  printf '请先运行 scripts/07-build-on-demand-gateway.sh，或用 --gateway 指定产物。\n' >&2
  exit 2
}

reserve_port() {
  python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

json_field() {
  local body="$1"
  local field="$2"
  python3 - "$body" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split('.'):
    if not isinstance(value, dict):
        raise SystemExit(1)
    value = value.get(part)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("null")
else:
    print(value)
PY
}

http_code() {
  local url="$1"
  local output="$2"
  local max_time="${3:-10}"
  curl --silent --show-error --output "$output" --write-out '%{http_code}' \
    --connect-timeout 2 --max-time "$max_time" "$url" 2>/dev/null || true
}

post_code() {
  local url="$1"
  local output="$2"
  local max_time="${3:-10}"
  curl --silent --show-error --output "$output" --write-out '%{http_code}' \
    --connect-timeout 2 --max-time "$max_time" \
    --form "file=@${AUDIO_FILE}" --form 'model=whisper-1' \
    --form 'response_format=json' "$url" 2>/dev/null || true
}

raw_content_length_post() {
  local port="$1"
  local body_file="$2"
  local content_type="$3"
  local result_file="$4"
  local connection_header="${5:-close}"
  python3 - "$port" "$body_file" "$content_type" "$result_file" "$connection_header" <<'PY'
import socket
import sys

port = int(sys.argv[1])
body = open(sys.argv[2], "rb").read()
content_type = sys.argv[3]
result_file = sys.argv[4]
connection_header = sys.argv[5]
request = (
    f"POST /v1/audio/transcriptions HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{port}\r\n"
    f"Content-Type: {content_type}\r\n"
    f"Content-Length: {len(body)}\r\n"
    f"Connection: {connection_header}\r\n\r\n"
).encode("ascii") + body

reply = b""
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    sock.settimeout(1 if connection_header.lower() == "keep-alive" else 5)
    sock.sendall(request)
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        reply += chunk
    sock.close()
except OSError:
    pass

status = "000"
connection = ""
if b"\r\n" in reply:
    try:
        status = reply.split(b"\r\n", 1)[0].split()[1].decode("ascii")
        header_blob = reply.split(b"\r\n\r\n", 1)[0].decode("latin1")
        for line in header_blob.split("\r\n")[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                if key.lower() == "connection":
                    connection = value.strip().lower()
    except (IndexError, UnicodeDecodeError):
        pass
with open(result_file, "w", encoding="ascii") as handle:
    handle.write(f"{status} {connection}\n")
PY
}

raw_chunked_post() {
  local port="$1"
  local boundary="$2"
  local epilogue_bytes="$3"
  local result_file="$4"
  local declared_content_length="${5:-}"
  python3 - "$port" "$boundary" "$epilogue_bytes" "$result_file" \
    "$declared_content_length" <<'PY'
import socket
import sys

port = int(sys.argv[1])
boundary = sys.argv[2]
epilogue_size = int(sys.argv[3])
result_file = sys.argv[4]
declared_content_length = sys.argv[5]
body = (
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="file"; filename="sample.wav"\r\n'
    "Content-Type: audio/wav\r\n\r\n"
).encode("ascii") + b"x" + f"\r\n--{boundary}--\r\n".encode("ascii")
body += b"E" * epilogue_size
chunks = []
for offset in range(0, len(body), 97):
    chunk = body[offset : offset + 97]
    chunks.append(f"{len(chunk):x}\r\n".encode("ascii") + chunk + b"\r\n")
chunks.append(b"0\r\n\r\n")
content_length_header = (
    f"Content-Length: {declared_content_length}\r\n"
    if declared_content_length else ""
)
request = (
    f"POST /v1/audio/transcriptions HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{port}\r\n"
    f"Content-Type: multipart/form-data; boundary={boundary}\r\n"
    f"{content_length_header}"
    "Transfer-Encoding: chunked\r\n"
    "Connection: close\r\n\r\n"
).encode("ascii") + b"".join(chunks)

reply = b""
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    sock.settimeout(5)
    sock.sendall(request)
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        reply += chunk
    sock.close()
except OSError:
    pass

status = "000"
if b"\r\n" in reply:
    try:
        status = reply.split(b"\r\n", 1)[0].split()[1].decode("ascii")
    except (IndexError, UnicodeDecodeError):
        pass
with open(result_file, "w", encoding="ascii") as handle:
    handle.write(status + "\n")
PY
}

raw_chunked_file_post() {
  local port="$1"
  local body_file="$2"
  local content_type="$3"
  local result_file="$4"
  local connection_header="${5:-close}"
  python3 - "$port" "$body_file" "$content_type" "$result_file" "$connection_header" <<'PY'
import socket
import sys

port = int(sys.argv[1])
body = open(sys.argv[2], "rb").read()
content_type = sys.argv[3]
result_file = sys.argv[4]
connection_header = sys.argv[5]
chunks = []
for offset in range(0, len(body), 97):
    chunk = body[offset : offset + 97]
    chunks.append(f"{len(chunk):x}\r\n".encode("ascii") + chunk + b"\r\n")
chunks.append(b"0\r\n\r\n")
request = (
    f"POST /v1/audio/transcriptions HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{port}\r\n"
    f"Content-Type: {content_type}\r\n"
    "Transfer-Encoding: chunked\r\n"
    f"Connection: {connection_header}\r\n\r\n"
).encode("ascii") + b"".join(chunks)

reply = b""
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    sock.settimeout(1 if connection_header.lower() == "keep-alive" else 5)
    sock.sendall(request)
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        reply += chunk
    sock.close()
except OSError:
    pass

status = "000"
connection = ""
if b"\r\n" in reply:
    try:
        status = reply.split(b"\r\n", 1)[0].split()[1].decode("ascii")
        header_blob = reply.split(b"\r\n\r\n", 1)[0].decode("latin1")
        for line in header_blob.split("\r\n")[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                if key.lower() == "connection":
                    connection = value.strip().lower()
    except (IndexError, UnicodeDecodeError):
        pass
with open(result_file, "w", encoding="ascii") as handle:
    handle.write(f"{status} {connection}\n")
PY
}

slow_content_length_post() {
  local port="$1"
  local body_file="$2"
  local content_type="$3"
  local interval_seconds="$4"
  local result_file="$5"
  python3 - "$port" "$body_file" "$content_type" "$interval_seconds" "$result_file" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
body = open(sys.argv[2], "rb").read()
content_type = sys.argv[3]
interval = float(sys.argv[4])
result_file = sys.argv[5]
request = (
    f"POST /v1/audio/transcriptions HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{port}\r\n"
    f"Content-Type: {content_type}\r\n"
    f"Content-Length: {len(body)}\r\n"
    "Connection: close\r\n\r\n"
).encode("ascii")

reply = b""
started = time.monotonic()
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    sock.settimeout(5)
    sock.sendall(request)
    for offset in range(0, len(body), 16):
        sock.sendall(body[offset : offset + 16])
        time.sleep(interval)
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        reply += chunk
    sock.close()
except OSError:
    pass

elapsed_ms = int((time.monotonic() - started) * 1000)
status = "000"
if b"\r\n" in reply:
    try:
        status = reply.split(b"\r\n", 1)[0].split()[1].decode("ascii")
    except (IndexError, UnicodeDecodeError):
        pass
with open(result_file, "w", encoding="ascii") as handle:
    handle.write(f"{elapsed_ms} {status}\n")
PY
}

bounded_queue_probe() {
  local port="$1"
  local flood_count="$2"
  local result_file="$3"
  python3 - "$port" "$flood_count" "$result_file" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
flood_count = int(sys.argv[2])
result_file = sys.argv[3]
header = (
    f"POST /v1/audio/transcriptions HTTP/1.1\r\n"
    f"Host: 127.0.0.1:{port}\r\n"
    "Content-Type: multipart/form-data; boundary=flood\r\n"
    "Content-Length: 100\r\n"
    "Connection: keep-alive\r\n\r\n"
).encode("ascii")

flood_sockets = []
for _ in range(flood_count):
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=1)
        sock.settimeout(1)
        sock.sendall(header)
        flood_sockets.append(sock)
    except OSError:
        break

started = time.monotonic()
status = "000"
try:
    probe = socket.create_connection(("127.0.0.1", port), timeout=2)
    probe.settimeout(1.5)
    probe.sendall(header)
    reply = b""
    while True:
        chunk = probe.recv(4096)
        if not chunk:
            break
        reply += chunk
    probe.close()
    if b"\r\n" in reply:
        try:
            status = reply.split(b"\r\n", 1)[0].split()[1].decode("ascii")
        except (IndexError, UnicodeDecodeError):
            pass
except OSError:
    pass
elapsed_ms = int((time.monotonic() - started) * 1000)

for sock in flood_sockets:
    try:
        sock.close()
    except OSError:
        pass

with open(result_file, "w", encoding="ascii") as handle:
    handle.write(f"{len(flood_sockets)} {elapsed_ms} {status}\n")
PY
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf '失败：%s（期望 %s，实际 %s）\n' "$message" "$expected" "$actual" >&2
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  grep -F -- "$pattern" "$file" >/dev/null || {
    printf '失败：%s；文件：%s\n' "$message" "$file" >&2
    sed -n '1,160p' "$file" >&2 || true
    return 1
  }
}

assert_file_equal() {
  local expected_file="$1"
  local actual_file="$2"
  local message="$3"
  cmp -s -- "$expected_file" "$actual_file" || {
    printf '失败：%s（期望文件 %s，实际文件 %s）\n' "$message" "$expected_file" "$actual_file" >&2
    return 1
  }
}

count_marker() {
  local pattern="$1"
  [[ -f "${MARKER_FILE}" ]] || { printf '0'; return 0; }
  grep -c -E -- "$pattern" "${MARKER_FILE}" || true
}

wait_for_code() {
  local url="$1"
  local expected="$2"
  local timeout_seconds="${3:-10}"
  local body="${CASE_DIR}/wait.body"
  local deadline
  deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    local code
    code="$(http_code "$url" "$body")"
    if [[ "$code" == "$expected" ]]; then
      return 0
    fi
    sleep 0.1
  done
  printf '失败：%s 在 %ss 内没有返回 HTTP %s。\n' "$url" "$timeout_seconds" "$expected" >&2
  [[ -f "$body" ]] && sed -n '1,160p' "$body" >&2 || true
  return 1
}

wait_for_field() {
  local url="$1"
  local field="$2"
  local expected="$3"
  local timeout_seconds="${4:-10}"
  local body="${CASE_DIR}/field.body"
  local deadline
  deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    local code value
    code="$(http_code "$url" "$body")"
    if [[ "$code" == "200" ]] && value="$(json_field "$body" "$field" 2>/dev/null)" && [[ "$value" == "$expected" ]]; then
      cp -- "$body" "${CASE_DIR}/last-health.json"
      return 0
    fi
    sleep 0.1
  done
  printf '失败：%s.%s 在 %ss 内没有变为 %s。\n' "$url" "$field" "$timeout_seconds" "$expected" >&2
  [[ -f "$body" ]] && sed -n '1,160p' "$body" >&2 || true
  return 1
}

write_audio_fixture() {
  AUDIO_FILE="${TMP_ROOT}/audio.bin"
  python3 - "$AUDIO_FILE" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(b"mock-audio\n" * 128)
PY
}

write_model_fixture() {
  printf 'isolated mock model fixture\n' >"${TEST_MODEL_FILE}"
  TEST_MODEL_SIZE="$(/usr/bin/stat -f '%z' "${TEST_MODEL_FILE}")"
  TEST_MODEL_SHA256="$(/usr/bin/shasum -a 256 "${TEST_MODEL_FILE}" | /usr/bin/awk '{print $1}')"
}

start_gateway() {
  local name="$1"
  local supplied_backend_port="${2:-}"

  BACKEND_BIN_REAL="${BACKEND_BIN}"

  CASE_DIR="${TMP_ROOT}/${name}"
  mkdir -p -- "${CASE_DIR}/uploads" "${CASE_DIR}/state" "${CASE_DIR}/run" "${CASE_DIR}/logs" "${CASE_DIR}/public"
  GW_PORT="$(reserve_port)"
  BACKEND_PORT="${supplied_backend_port:-$(reserve_port)}"
  if [[ "$GW_PORT" == "8080" || "$GW_PORT" == "18080" || "$BACKEND_PORT" == "8080" || "$BACKEND_PORT" == "18080" ]]; then
    printf '安全检查失败：测试意外选择正式端口。\n' >&2
    return 1
  fi
  GW_URL="http://127.0.0.1:${GW_PORT}"
  MARKER_FILE="${CASE_DIR}/backend.events"
  GW_LOG="${CASE_DIR}/gateway.log"
  : >"${MARKER_FILE}"

  # This stale file is intentionally older than one day. A production gateway
  # should remove it during startup, while a live request's file should be
  # removed immediately after completion.
  printf 'stale-upload' >"${CASE_DIR}/uploads/stale.multipart"
  python3 - "${CASE_DIR}/uploads/stale.multipart" <<'PY'
import os
import sys
import time

old = time.time() - (48 * 60 * 60)
os.utime(sys.argv[1], (old, old))
PY

  local -a gateway_env
  local -a gateway_args
  gateway_args=(
    --gateway-host 127.0.0.1
    --gateway-port "${GW_PORT}"
    --backend-port "${BACKEND_PORT}"
  )
  gateway_env=(
    env
    "WHISPER_INSTALL_ROOT=${PROJECT_ROOT}"
    "WHISPER_PROJECT_ROOT=${PROJECT_ROOT}"
    "WHISPER_GATEWAY_PORT=${GW_PORT}"
    "WHISPER_BACKEND_PORT=${BACKEND_PORT}"
    "WHISPER_INFERENCE_PATH=/v1/audio/transcriptions"
    "WHISPER_BACKEND_INFERENCE_PATH=/v1/audio/transcriptions"
    "WHISPER_MODEL=large-v3-turbo"
    "WHISPER_MODEL_PATH=${TEST_MODEL_FILE}"
    "WHISPER_MODEL_FILE=${TEST_MODEL_FILE}"
    "WHISPER_COMMIT=306c88f4d1286aec1bf96e544632897886af5501"
    "WHISPER_MODEL_SHA256=${TEST_MODEL_SHA256}"
    "WHISPER_MODEL_SIZE_BYTES=${TEST_MODEL_SIZE}"
    "WHISPER_LANGUAGE=auto"
    "WHISPER_THREADS=1"
    "WHISPER_PUBLIC_DIR=${CASE_DIR}/public"
    "WHISPER_BACKEND_BIN=${BACKEND_BIN}"
    "WHISPER_SERVER_BIN=${BACKEND_BIN}"
    "WHISPER_TEST_BACKEND_BIN=${BACKEND_BIN}"
    "WHISPER_BACKEND_COMMAND=${BACKEND_BIN}"
    "WHISPER_BACKEND_ARGS="
    "WHISPER_UPLOAD_DIR=${CASE_DIR}/uploads"
    "WHISPER_STATE_DIR=${CASE_DIR}/state"
    "WHISPER_RUN_DIR=${CASE_DIR}/run"
    "WHISPER_LOG_DIR=${CASE_DIR}/logs"
    "WHISPER_GATEWAY_PID_FILE=${CASE_DIR}/run/gateway.pid"
    "WHISPER_ON_DEMAND_PID_FILE=${CASE_DIR}/run/backend.state"
    "WHISPER_BACKEND_PID_FILE=${CASE_DIR}/run/backend.state"
    "WHISPER_ON_DEMAND_BACKEND_LOG=${CASE_DIR}/logs/backend.log"
    "WHISPER_GATEWAY_STATE_DIR=${CASE_DIR}/state"
    "WHISPER_GATEWAY_RUN_DIR=${CASE_DIR}/run"
    "WHISPER_GATEWAY_LOG_DIR=${CASE_DIR}/logs"
    "WHISPER_IDLE_TIMEOUT_SECONDS=${IDLE_TIMEOUT_SECONDS:-2}"
    "WHISPER_STARTUP_TIMEOUT_SECONDS=${STARTUP_TIMEOUT_SECONDS:-3}"
    "WHISPER_SHUTDOWN_TIMEOUT_SECONDS=2"
    "WHISPER_REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-10}"
    "WHISPER_MAX_PENDING_REQUESTS=${MAX_PENDING_REQUESTS:-4}"
    "WHISPER_MAX_UPLOAD_BYTES=${MAX_UPLOAD_BYTES:-268435456}"
    "WHISPER_START_FAILURE_BACKOFF_SECONDS=${START_FAILURE_BACKOFF_SECONDS:-2}"
    "MOCK_STARTUP_DELAY_MS=${MOCK_STARTUP_DELAY_MS:-0}"
    "MOCK_READY_DELAY_MS=${MOCK_READY_DELAY_MS:-0}"
    "MOCK_REQUEST_DELAY_MS=${MOCK_REQUEST_DELAY_MS:-0}"
    "MOCK_CRASH_AFTER=${MOCK_CRASH_AFTER:-0}"
    "MOCK_EXIT_AFTER_MS=${MOCK_EXIT_AFTER_MS:-0}"
    "MOCK_MARKER_FILE=${MARKER_FILE}"
    "MOCK_CAPTURE_BODY_FILE=${CAPTURE_BODY_FILE}"
    "MOCK_CAPTURE_HEADERS_FILE=${CAPTURE_HEADERS_FILE}"
    "MOCK_RESPONSE_TEXT=mock transcription"
  )

  "${gateway_env[@]}" "${GATEWAY_BIN}" "${gateway_args[@]}" >"${GW_LOG}" 2>&1 &
  GW_PID=$!
  wait_for_code "${GW_URL}/health" 200 5
}

stop_gateway() {
  if [[ -n "${GW_PID:-}" ]]; then
    kill -TERM "${GW_PID}" 2>/dev/null || true
    local deadline=$((SECONDS + 5))
    while kill -0 "${GW_PID}" 2>/dev/null && ((SECONDS < deadline)); do
      sleep 0.1
    done
    if kill -0 "${GW_PID}" 2>/dev/null; then
      kill -KILL "${GW_PID}" 2>/dev/null || true
    fi
    wait "${GW_PID}" 2>/dev/null || true
    GW_PID=""
  fi
}

run_post() {
  local output="$1"
  local max_time="${2:-10}"
  post_code "${GW_URL}/v1/audio/transcriptions" "$output" "$max_time"
}

assert_clean_uploads() {
  local leftovers
  leftovers="$(find "${CASE_DIR}/uploads" -type f -print 2>/dev/null || true)"
  [[ -z "$leftovers" ]] || {
    printf '失败：临时上传文件未清理：\n%s\n' "$leftovers" >&2
    return 1
  }
}

run_case() {
  local name="$1"
  shift
  printf '\n[%s]\n' "$name"
  "$@"
  stop_gateway
  unset IDLE_TIMEOUT_SECONDS STARTUP_TIMEOUT_SECONDS REQUEST_TIMEOUT_SECONDS MAX_PENDING_REQUESTS MAX_UPLOAD_BYTES START_FAILURE_BACKOFF_SECONDS
  unset MOCK_STARTUP_DELAY_MS MOCK_READY_DELAY_MS MOCK_REQUEST_DELAY_MS MOCK_CRASH_AFTER MOCK_EXIT_AFTER_MS
  BACKEND_BIN="${MOCK_BIN}"
  CAPTURE_BODY_FILE=""
  CAPTURE_HEADERS_FILE=""
  printf '通过：%s\n' "$name"
  RUN_CASE_COUNT=$((RUN_CASE_COUNT + 1))
}

maybe_run_case() {
  local key="$1"
  shift
  if [[ -n "${ON_DEMAND_TEST_CASE:-}" && "${ON_DEMAND_TEST_CASE}" != "$key" ]]; then
    return 0
  fi
  run_case "$@"
}

case_cold_health_and_routes() {
  start_gateway cold-health
  assert_equal 0 "$(count_marker '^start$')" 'cold health 不应启动后端'
  local health_body="${CASE_DIR}/health.json"
  assert_equal 200 "$(http_code "${GW_URL}/health" "$health_body")" '网关 health'
  assert_equal ok "$(json_field "$health_body" status)" 'health status'
  assert_equal cold "$(json_field "$health_body" backend)" 'health backend=cold'
  assert_equal 503 "$(http_code "${GW_URL}/ready" "${CASE_DIR}/ready.json")" 'cold ready 应为 503'
  local options_headers="${CASE_DIR}/options.headers"
  assert_equal 204 "$(curl --silent --show-error --dump-header "$options_headers" --output /dev/null --write-out '%{http_code}' \
    --request OPTIONS -H 'Origin: http://localhost' -H 'Access-Control-Request-Method: POST' \
    "${GW_URL}/v1/audio/transcriptions")" 'CORS OPTIONS'
  assert_file_contains "$options_headers" 'Access-Control-Allow-Origin: *' 'CORS header'
  assert_equal 404 "$(http_code "${GW_URL}/load" "${CASE_DIR}/load.body")" '未允许的 /load 路由'
  assert_equal 404 "$(http_code "${GW_URL}/" "${CASE_DIR}/root.body")" '未允许的根路由'

  assert_equal 200 "$(run_post "${CASE_DIR}/post.json")" '冷启动首个请求'
  assert_file_contains "${CASE_DIR}/post.json" 'mock transcription' 'mock JSON 响应'
  wait_for_code "${GW_URL}/ready" 200 5
  assert_equal 1 "$(count_marker '^start$')" '首个请求只启动一个后端'
  assert_clean_uploads
}

case_single_flight_and_warm_reuse() {
  MOCK_STARTUP_DELAY_MS=500
  IDLE_TIMEOUT_SECONDS=3
  start_gateway single-flight
  local first="${CASE_DIR}/first.json" second="${CASE_DIR}/second.json"
  post_code "${GW_URL}/v1/audio/transcriptions" "$first" 10 >"${CASE_DIR}/first.code" &
  local first_pid=$!
  sleep 0.05
  post_code "${GW_URL}/v1/audio/transcriptions" "$second" 10 >"${CASE_DIR}/second.code" &
  local second_pid=$!
  wait "$first_pid"
  wait "$second_pid"
  assert_equal 200 "$(<"${CASE_DIR}/first.code")" 'single-flight 首请求'
  assert_equal 200 "$(<"${CASE_DIR}/second.code")" 'single-flight 并发请求'
  assert_equal 1 "$(count_marker '^start$')" '并发冷请求共享一次启动'

  assert_equal 200 "$(run_post "${CASE_DIR}/warm.json")" 'warm 请求'
  assert_equal 1 "$(count_marker '^start$')" 'warm 请求复用后端'
  assert_clean_uploads
}

case_known_length_starts_backend_while_uploading() {
  MAX_UPLOAD_BYTES=8192
  start_gateway known-length-early-start
  local body_file="${CASE_DIR}/slow-known.multipart"
  local result_file="${CASE_DIR}/slow-known.result"
  python3 - "$body_file" <<'PY'
import pathlib
import sys

boundary = "known-length"
body = (
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="file"; filename="slow.wav"\r\n'
    "Content-Type: audio/wav\r\n\r\n"
).encode("ascii") + (b"K" * 1024) + (
    f"\r\n--{boundary}--\r\n"
).encode("ascii")
pathlib.Path(sys.argv[1]).write_bytes(body)
PY
  slow_content_length_post "$GW_PORT" "$body_file" \
    'multipart/form-data; boundary=known-length' 0.05 "$result_file" &
  local upload_pid=$!
  local deadline=$((SECONDS + 2))
  while ((SECONDS < deadline)) && [[ "$(count_marker '^start$')" != "1" ]]; do
    sleep 0.05
  done
  assert_equal 1 "$(count_marker '^start$')" \
    '定长慢上传完成前应已启动后端'
  wait "$upload_pid"
  local elapsed_ms status
  read -r elapsed_ms status <"$result_file"
  assert_equal 200 "$status" '定长慢上传最终应成功'
  assert_clean_uploads
}

case_active_and_queue_limit() {
  MOCK_REQUEST_DELAY_MS=1200
  MAX_PENDING_REQUESTS=1
  IDLE_TIMEOUT_SECONDS=3
  start_gateway active-limit
  local first="${CASE_DIR}/slow.json"
  post_code "${GW_URL}/v1/audio/transcriptions" "$first" 10 >"${CASE_DIR}/slow.code" &
  local first_pid=$!
  sleep 0.2
  wait_for_field "${GW_URL}/health" active_requests 1 5
  assert_equal 429 "$(run_post "${CASE_DIR}/rejected.json" 2)" '超过 pending 上限返回 429'
  wait "$first_pid"
  assert_equal 200 "$(<"${CASE_DIR}/slow.code")" '慢请求仍成功'
  wait_for_field "${GW_URL}/health" active_requests 0 5
  assert_clean_uploads
}

case_idle_exit_and_second_wake() {
  IDLE_TIMEOUT_SECONDS=1
  start_gateway idle-exit
  assert_equal 200 "$(run_post "${CASE_DIR}/first.json")" 'idle 首次请求'
  assert_equal 1 "$(count_marker '^start$')" 'idle 首次 PID'
  wait_for_field "${GW_URL}/health" backend cold 5
  assert_equal 200 "$(run_post "${CASE_DIR}/second.json")" 'idle 二次唤醒'
  assert_equal 2 "$(count_marker '^start$')" 'idle 二次请求创建新后端'
  assert_clean_uploads
}

case_limits_and_cleanup() {
  MAX_UPLOAD_BYTES=64
  start_gateway upload-limit
  local oversized="${CASE_DIR}/oversized.bin"
  python3 - "$oversized" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(b"oversized-upload" * 32)
PY
  assert_equal 413 "$(curl --silent --show-error --output "${CASE_DIR}/too-large.body" --write-out '%{http_code}' \
    --connect-timeout 2 --max-time 5 --form "file=@${oversized}" \
    --form 'model=whisper-1' "${GW_URL}/v1/audio/transcriptions" 2>/dev/null || true)" '超过上传限制返回 413'
  assert_equal 0 "$(count_marker '^start$')" '413 不应启动后端'
  assert_clean_uploads
}

case_chunked_epilogue_limit() {
  MAX_UPLOAD_BYTES=256
  start_gateway chunked-epilogue-limit
  local result_file="${CASE_DIR}/chunked.result"
  raw_chunked_post "$GW_PORT" chunked-limit 4096 "$result_file"
  assert_equal 413 "$(<"$result_file")" 'chunked multipart 总大小超过上限返回 413'
  assert_equal 0 "$(count_marker '^start$')" 'chunked 超限请求不应启动后端'

  local te_cl_result="${CASE_DIR}/te-cl.result"
  raw_chunked_post "$GW_PORT" te-cl-limit 4096 "$te_cl_result" 1
  assert_equal 400 "$(<"$te_cl_result")" 'TE+CL 请求必须在读取前拒绝'
  assert_equal 0 "$(count_marker '^start$')" 'TE+CL 超限请求不应启动后端'
  assert_clean_uploads
}

case_raw_multipart_preservation() {
  BACKEND_BIN="${RAW_MOCK_BIN}"
  CAPTURE_BODY_FILE="${TMP_ROOT}/raw-multipart/backend.body"
  CAPTURE_HEADERS_FILE="${TMP_ROOT}/raw-multipart/backend.headers"
  start_gateway raw-multipart
  local body_file="${CASE_DIR}/original.multipart"
  local result_file="${CASE_DIR}/raw.result"
  python3 - "$body_file" <<'PY'
import pathlib
import sys

boundary = "raw+boundary._/"
body = (
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="file"; filename="sample.wav"\r\n'
    "Content-Type: audio/wav; codec=pcm\r\n"
    "X-Part-Header: preserve-me\r\n"
    "Content-ID: <part-1>\r\n\r\n"
).encode("ascii") + b"\x00\x01raw-audio\r\n" + (
    f"\r\n--{boundary}\r\n"
    'Content-Disposition: form-data; name="model"\r\n'
    "X-Model-Header: preserve-model\r\n\r\n"
    "whisper-1\r\n"
    f"--{boundary}--\r\n"
).encode("ascii")
pathlib.Path(sys.argv[1]).write_bytes(body)
PY
  raw_content_length_post "$GW_PORT" "$body_file" \
    'multipart/form-data; boundary="raw+boundary._/"' "$result_file"
  assert_equal 200 "$(awk '{print $1}' "$result_file")" '合法特殊 boundary 的 multipart 请求'
  [[ -f "$CAPTURE_BODY_FILE" ]] || {
    printf '失败：raw backend 未捕获请求体。\n' >&2
    return 1
  }
  assert_file_equal "$body_file" "$CAPTURE_BODY_FILE" 'multipart body 必须原样转发（含额外 part header）'
  assert_file_contains "$CAPTURE_HEADERS_FILE" 'Content-Type: multipart/form-data; boundary="raw+boundary._/"' \
    '转发请求必须保留原始 Content-Type boundary'
  assert_clean_uploads
}

case_early_errors_close_connection() {
  MAX_UPLOAD_BYTES=256
  start_gateway early-errors-close
  local invalid_body="${CASE_DIR}/invalid.body"
  local invalid_result="${CASE_DIR}/invalid.result"
  printf 'bad-body' >"$invalid_body"
  raw_content_length_post "$GW_PORT" "$invalid_body" application/octet-stream "$invalid_result" keep-alive
  assert_equal '400 close' "$(<"$invalid_result")" '提前 400 必须关闭连接'

  local overflow_body="${CASE_DIR}/overflow.multipart"
  local overflow_result="${CASE_DIR}/overflow.result"
  python3 - "$overflow_body" <<'PY'
import pathlib
import sys

boundary = "overflow"
body = (
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="file"; filename="large.wav"\r\n'
    "Content-Type: audio/wav\r\n\r\n"
).encode("ascii") + (b"O" * 2048) + (
    f"\r\n--{boundary}--\r\n"
).encode("ascii")
pathlib.Path(sys.argv[1]).write_bytes(body)
PY
  raw_chunked_file_post "$GW_PORT" "$overflow_body" \
    'multipart/form-data; boundary=overflow' "$overflow_result" keep-alive
  assert_equal '413 close' "$(<"$overflow_result")" '提前 413 必须关闭连接'
  assert_clean_uploads
}

case_request_total_deadline() {
  REQUEST_TIMEOUT_SECONDS=1
  MAX_UPLOAD_BYTES=4096
  start_gateway slow-upload-deadline
  local body_file="${CASE_DIR}/slow.multipart"
  local result_file="${CASE_DIR}/slow.result"
  python3 - "$body_file" <<'PY'
import pathlib
import sys

boundary = "slow-deadline"
body = (
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="file"; filename="slow.wav"\r\n'
    "Content-Type: audio/wav\r\n\r\n"
).encode("ascii") + (b"S" * 480) + (
    f"\r\n--{boundary}--\r\n"
).encode("ascii")
pathlib.Path(sys.argv[1]).write_bytes(body)
PY
  # 16-byte writes every 50 ms keep each socket read below the 1-second
  # per-operation timeout while taking roughly 1.8 seconds in total.  A
  # request-wide deadline must terminate this before the body completes.
  slow_content_length_post "$GW_PORT" "$body_file" \
    'multipart/form-data; boundary=slow-deadline' 0.05 "$result_file"
  local elapsed_ms status
  read -r elapsed_ms status <"$result_file"
  if ((elapsed_ms >= 1600)); then
    printf '失败：总请求 deadline 未生效（耗时 %sms，状态 %s）。\n' "$elapsed_ms" "$status" >&2
    return 1
  fi
  assert_clean_uploads
}

case_bounded_queue_probe() {
  REQUEST_TIMEOUT_SECONDS=1
  MAX_PENDING_REQUESTS=64
  start_gateway bounded-queue
  local result_file="${CASE_DIR}/queue.result"
  bounded_queue_probe "$GW_PORT" 64 "$result_file"
  local accepted elapsed_ms status
  read -r accepted elapsed_ms status <"$result_file"
  if ((accepted < 60)); then
    printf '失败：压力请求未能建立足够连接（只建立 %s）。\n' "$accepted" >&2
    return 1
  fi
  if ((elapsed_ms >= 1200)); then
    printf '失败：超出 bounded queue 的 probe 挂起 %sms（状态 %s）。\n' "$elapsed_ms" "$status" >&2
    return 1
  fi
  [[ "$status" != "200" ]] || {
    printf '失败：超出队列上限的 probe 不应返回 200。\n' >&2
    return 1
  }
  assert_clean_uploads
}

case_startup_failure_and_backoff() {
  MOCK_STARTUP_DELAY_MS=5000
  STARTUP_TIMEOUT_SECONDS=1
  START_FAILURE_BACKOFF_SECONDS=2
  start_gateway startup-failure
  assert_equal 503 "$(run_post "${CASE_DIR}/timeout.json" 4)" '启动超时返回 503'
  assert_equal 503 "$(run_post "${CASE_DIR}/backoff.json" 2)" '退避期间返回 503'
  assert_equal 1 "$(count_marker '^start$')" '退避期间不重复创建后端'
  assert_clean_uploads
}

case_backend_crash() {
  MOCK_CRASH_AFTER=1
  START_FAILURE_BACKOFF_SECONDS=2
  start_gateway backend-crash
  assert_equal 502 "$(run_post "${CASE_DIR}/crash.json" 5)" '后端异常退出返回 502'
  wait_for_field "${GW_URL}/health" backend backoff 5
  assert_equal 503 "$(run_post "${CASE_DIR}/crash-backoff.json" 2)" '后端崩溃后进入退避'
  assert_clean_uploads
}

start_foreign_server() {
  local port="$1"
  python3 - "$port" >"${CASE_DIR}/foreign.log" 2>&1 <<'PY' &
import http.server
import socketserver
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(418)
        self.end_headers()
        self.wfile.write(b"foreign")

    def log_message(self, *_args):
        pass

with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), Handler) as server:
    server.serve_forever()
PY
  FOREIGN_PID=$!
  sleep 0.2
  kill -0 "$FOREIGN_PID" 2>/dev/null
}

case_foreign_port() {
  CASE_DIR="${TMP_ROOT}/foreign-port"
  mkdir -p -- "${CASE_DIR}/uploads" "${CASE_DIR}/state" "${CASE_DIR}/run" "${CASE_DIR}/logs" "${CASE_DIR}/public"
  BACKEND_PORT="$(reserve_port)"
  MARKER_FILE="${CASE_DIR}/backend.events"
  : >"${MARKER_FILE}"
  start_foreign_server "$BACKEND_PORT"
  start_gateway foreign-port "$BACKEND_PORT"
  assert_equal 200 "$(http_code "${GW_URL}/health" "${CASE_DIR}/health.json")" 'foreign port 不影响网关 health'
  assert_equal 503 "$(run_post "${CASE_DIR}/foreign-post.json" 3)" 'foreign backend port 返回 503'
  kill -0 "$FOREIGN_PID" 2>/dev/null || {
    printf '失败：网关不应终止占用后端端口的未知进程。\n' >&2
    return 1
  }
  kill -TERM "$FOREIGN_PID" 2>/dev/null || true
  wait "$FOREIGN_PID" 2>/dev/null || true
  FOREIGN_PID=""
}

case_client_disconnect() {
  MOCK_REQUEST_DELAY_MS=1500
  IDLE_TIMEOUT_SECONDS=3
  start_gateway disconnect
  curl --silent --show-error --output "${CASE_DIR}/disconnect.body" \
    --connect-timeout 2 --max-time 0.2 \
    --form "file=@${AUDIO_FILE}" --form 'model=whisper-1' \
    "${GW_URL}/v1/audio/transcriptions" >"${CASE_DIR}/disconnect.code" 2>/dev/null || true
  wait_for_field "${GW_URL}/health" active_requests 0 5
  assert_clean_uploads
}

write_model_fixture
write_audio_fixture

maybe_run_case cold-health 'cold health、路由和 CORS' case_cold_health_and_routes
maybe_run_case single-flight 'single-flight 与 warm reuse' case_single_flight_and_warm_reuse
maybe_run_case known-length-early-start '定长慢上传期间提前启动后端' case_known_length_starts_backend_while_uploading
maybe_run_case active-limit 'active 保护与 429 队列限制' case_active_and_queue_limit
maybe_run_case idle-exit 'idle exit 与二次唤醒' case_idle_exit_and_second_wake
maybe_run_case upload-limit '413 与临时文件清理' case_limits_and_cleanup
maybe_run_case chunked-epilogue-limit 'chunked epilogue 上传总量限制' case_chunked_epilogue_limit
maybe_run_case raw-multipart 'raw multipart boundary 和 part header 原样转发' case_raw_multipart_preservation
maybe_run_case early-errors-close '提前 400/413 关闭连接' case_early_errors_close_connection
maybe_run_case slow-upload-deadline '慢上传总请求 deadline' case_request_total_deadline
maybe_run_case bounded-queue 'bounded queue 超限 probe' case_bounded_queue_probe
maybe_run_case startup-failure '启动失败与 backoff' case_startup_failure_and_backoff
maybe_run_case backend-crash 'backend crash' case_backend_crash
maybe_run_case foreign-port 'foreign backend port' case_foreign_port
maybe_run_case disconnect 'client disconnect' case_client_disconnect

if [[ -n "${ON_DEMAND_TEST_CASE:-}" ]]; then
  (( RUN_CASE_COUNT == 1 )) || {
    printf '错误：未知或重复的 ON_DEMAND_TEST_CASE：%s\n' \
      "${ON_DEMAND_TEST_CASE}" >&2
    exit 2
  }
else
  (( RUN_CASE_COUNT == 15 )) || {
    printf '错误：集成测试数量不完整：实际 %s，预期 15。\n' \
      "${RUN_CASE_COUNT}" >&2
    exit 2
  }
fi

printf '\n全部按需网关集成测试通过。使用的端口均为临时 loopback 端口；未触碰 8080/18080 或 LaunchAgent。\n'
