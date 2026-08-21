#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
UNINSTALL_SCRIPT="${TEST_ROOT}/uninstall.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/whisper-uninstall-test.XXXXXX")"
TMP_ROOT="$(cd "${TMP_ROOT}" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() { [[ -f "$1" ]] || fail "expected file: $1"; }
assert_dir() { [[ -d "$1" ]] || fail "expected directory: $1"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "expected absent: $1"; }
assert_equal() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

make_shim() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/launchctl" <<'EOF'
#!/usr/bin/env bash
set -eu
state_dir="${WHISPER_FIXTURE_STATE:?}"
case "${1:-}" in
  print) [[ -f "${state_dir}/launchd.loaded" ]] ;;
  bootout) rm -f -- "${state_dir}/launchd.loaded" ;;
  *) exit 2 ;;
esac
EOF
  cat >"${bin_dir}/socketfilterfw" <<'EOF'
#!/usr/bin/env bash
set -eu
state_dir="${WHISPER_FIXTURE_STATE:?}"
case "${1:-}" in
  --listapps)
    [[ -f "${state_dir}/firewall" ]] && cat "${state_dir}/firewall"
    ;;
  --getglobalstate) echo 'Firewall is enabled. (State = 1)' ;;
  --remove)
    path="${2:?missing path}"
    tmp="${state_dir}/firewall.tmp"
    : >"${tmp}"
    if [[ -f "${state_dir}/firewall" ]]; then
      while IFS= read -r line; do
        parsed="$(printf '%s\n' "${line}" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]*:[[:space:]]*//')"
        [[ "${parsed}" == "${path}" ]] || printf '%s\n' "${line}" >>"${tmp}"
      done <"${state_dir}/firewall"
    fi
    mv -f -- "${tmp}" "${state_dir}/firewall"
    ;;
  *) exit 2 ;;
esac
EOF
cat >"${bin_dir}/sudo" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == -v ]]; then
  [[ "${WHISPER_FIXTURE_SUDO_FAIL:-0}" == 1 ]] && exit 1
  exit 0
fi
exec "$@"
EOF
  cat >"${bin_dir}/lsof" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ -n "${WHISPER_FIXTURE_LISTENER:-}" ]]; then
  printf '%s\n' "${WHISPER_FIXTURE_LISTENER}"
fi
EOF
  cat >"${bin_dir}/ps" <<'EOF'
#!/usr/bin/env bash
set -eu
process_output() {
  if [[ ! -f "${WHISPER_FIXTURE_STATE:?}/launchd.loaded" &&
        -n "${WHISPER_FIXTURE_PS_AFTER_BOOTOUT:-}" ]]; then
    printf '%s\n' "${WHISPER_FIXTURE_PS_AFTER_BOOTOUT}"
  elif [[ -n "${WHISPER_FIXTURE_PS_OUTPUT:-}" ]]; then
    printf '%s\n' "${WHISPER_FIXTURE_PS_OUTPUT}"
  fi
}
case "${1:-}" in
  -axo)
    process_output | while IFS= read -r command; do
      printf '%s %s\n' "${WHISPER_FIXTURE_PS_PID:-4242}" "${command}"
    done
    ;;
  -p)
    process_output
    ;;
esac
EOF
  chmod 755 "${bin_dir}/lsof" "${bin_dir}/ps"
  chmod 755 "${bin_dir}/launchctl" "${bin_dir}/socketfilterfw" "${bin_dir}/sudo"
}

make_git_source() {
  local source_dir="$1"
  mkdir -p "${source_dir}"
  git -C "${source_dir}" init -q
  git -C "${source_dir}" config user.email test@example.invalid
  git -C "${source_dir}" config user.name uninstall-test
  printf 'fixture\n' >"${source_dir}/README"
  git -C "${source_dir}" add README
  git -C "${source_dir}" commit -q -m fixture
  git -C "${source_dir}" rev-parse HEAD
}

make_fixture() {
  local name="$1" fixture install_root app_root home state bin commit
  fixture="${TMP_ROOT}/${name}"
  install_root="${fixture}/checkout"
  app_root="${fixture}/Application Support/whisper-custom-host"
  home="${fixture}/home"
  state="${fixture}/state"
  bin="${fixture}/bin"
  mkdir -p "${install_root}/scripts" "${home}/Library/LaunchAgents" \
    "${home}/Library/Logs/whisper-custom-host" "${state}" "${app_root}/runtime/run" \
    "${app_root}/bin" "${install_root}/build" "${install_root}/var" "${install_root}/models"
  touch "${install_root}/install.sh" "${install_root}/.env" "${install_root}/models/root-model.bin" \
    "${install_root}/keep-untracked.txt" "${install_root}/build/build.bin" "${install_root}/var/log.txt" \
    "${app_root}/runtime/extra.log" "${home}/Library/Logs/whisper-custom-host/out.log"
  commit="$(make_git_source "${install_root}/third_party/whisper.cpp")"
  {
    printf 'WHISPER_INSTALL_ROOT=%q\n' "${install_root}"
    printf 'WHISPER_APP_SUPPORT_ROOT=%q\n' "${app_root}"
    printf 'WHISPER_MODEL=large-v3-turbo\n'
    printf 'WHISPER_COMMIT=%q\n' "${commit}"
    printf 'WHISPER_HOST=0.0.0.0\nWHISPER_PORT=8080\n'
    printf 'WHISPER_GATEWAY_PORT=8080\nWHISPER_BACKEND_PORT=18080\n'
    printf 'WHISPER_SHUTDOWN_TIMEOUT_SECONDS=1\n'
  } >"${install_root}/config.env"
  cat >"${home}/Library/LaunchAgents/com.local.whisper-on-demand-gateway.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>com.local.whisper-on-demand-gateway</string>
<key>ProgramArguments</key><array><string>${app_root}/bin/whisper-on-demand-gateway</string></array>
<key>EnvironmentVariables</key><dict><key>WHISPER_CUSTOM_HOST_MANAGED_BY</key><string>whisper-custom-host/08-on-demand-service.sh</string></dict>
</dict></plist>
EOF
  printf '1 : %s\n2 : %s\n3 : %s\n4 : %s\n' "${app_root}/bin/whisper-on-demand-gateway" \
    "${install_root}/build/whisper.cpp/bin/whisper-server" \
    "${fixture}/old/whisper-custom-host/bin/whisper-server" \
    "${install_root}/build/on-demand/bin/whisper-on-demand-gateway" >"${state}/firewall"
  : >"${state}/launchd.loaded"
  make_shim "${bin}"
  printf '%s\n' "${fixture}|${install_root}|${app_root}|${home}|${state}|${bin}"
}

run_uninstall() {
  local config="$1" home="$2" state="$3" bin="$4" mode="$5"
  HOME="${home}" WHISPER_CONFIG_FILE="${config}" WHISPER_UNINSTALL_UNAME=Darwin \
    WHISPER_UNINSTALL_LAUNCHCTL="${bin}/launchctl" \
    WHISPER_UNINSTALL_PLUTIL=/usr/bin/plutil \
    WHISPER_UNINSTALL_LSOF="${bin}/lsof" \
    WHISPER_UNINSTALL_FIREWALL_TOOL="${bin}/socketfilterfw" \
    WHISPER_UNINSTALL_SUDO="${bin}/sudo" WHISPER_FIXTURE_STATE="${state}" \
    WHISPER_UNINSTALL_PS="${bin}/ps" \
    WHISPER_FIXTURE_PS_AFTER_BOOTOUT="${WHISPER_FIXTURE_PS_AFTER_BOOTOUT:-}" \
    WHISPER_UNINSTALL_TEST_MODE=1 "${UNINSTALL_SCRIPT}" "${mode}"
}

run_uninstall_expect_fail() {
  local config="$1" home="$2" state="$3" bin="$4" mode="$5"
  if run_uninstall "${config}" "${home}" "${state}" "${bin}" "${mode}"; then
    fail "expected uninstall failure"
  fi
}

run_uninstall_no_mode_expect_fail() {
  local config="$1" home="$2" state="$3" bin="$4"
  if HOME="${home}" WHISPER_CONFIG_FILE="${config}" WHISPER_UNINSTALL_UNAME=Darwin \
    WHISPER_UNINSTALL_LAUNCHCTL="${bin}/launchctl" \
    WHISPER_UNINSTALL_LSOF="${bin}/lsof" \
    WHISPER_UNINSTALL_FIREWALL_TOOL="${bin}/socketfilterfw" \
    WHISPER_UNINSTALL_SUDO="${bin}/sudo" WHISPER_UNINSTALL_PS="${bin}/ps" \
    WHISPER_FIXTURE_STATE="${state}" \
    WHISPER_UNINSTALL_TEST_MODE=1 "${UNINSTALL_SCRIPT}"; then
    fail 'expected non-TTY uninstall failure'
  fi
}

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture dry-run)
EOF
run_uninstall "${install_root}/config.env" "${home}" "${state}" "${bin}" --dry-run
assert_file "${install_root}/.env"
assert_dir "${install_root}/build"
assert_dir "${app_root}"
assert_file "${state}/launchd.loaded"
assert_file "${state}/firewall"
run_uninstall_no_mode_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture nonowned)
EOF
sed -i '' 's/whisper-custom-host\/08-on-demand-service\.sh/not-this-project/' \
  "${home}/Library/LaunchAgents/com.local.whisper-on-demand-gateway.plist"
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
assert_dir "${app_root}"
assert_file "${state}/launchd.loaded"
assert_file "${state}/firewall"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture dirty)
EOF
printf 'dirty\n' >>"${install_root}/third_party/whisper.cpp/README"
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
assert_dir "${install_root}/build"
assert_dir "${app_root}"
assert_file "${state}/launchd.loaded"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture symlink)
EOF
mv "${app_root}" "${fixture}/app-target"
ln -s "${fixture}/app-target" "${app_root}"
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
assert_dir "${fixture}/app-target"
assert_file "${state}/launchd.loaded"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture ancestor-symlink)
EOF
mkdir -p "${fixture}/real-parent"
mv "${install_root}" "${fixture}/real-parent/checkout"
ln -s "${fixture}/real-parent" "${fixture}/linked-parent"
sed -i '' "s|${fixture}/checkout|${fixture}/linked-parent/checkout|" \
  "${fixture}/real-parent/checkout/config.env"
run_uninstall_expect_fail "${fixture}/real-parent/checkout/config.env" "${home}" "${state}" "${bin}" --yes
assert_dir "${fixture}/real-parent/checkout"
assert_file "${state}/launchd.loaded"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture unmanaged-process)
EOF
rm -f -- "${state}/launchd.loaded"
export WHISPER_FIXTURE_PS_OUTPUT="${app_root}/bin/whisper-on-demand-gateway --gateway-port 8080 --backend-port 18080 --inference-path /v1/audio/transcriptions --model ${app_root}/runtime/models/ggml-large-v3-turbo.bin"
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
unset WHISPER_FIXTURE_PS_OUTPUT
assert_dir "${app_root}"
assert_file "${state}/firewall"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture unmanaged-listener)
EOF
export WHISPER_FIXTURE_LISTENER=4242
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
unset WHISPER_FIXTURE_LISTENER
assert_dir "${app_root}"
assert_file "${state}/launchd.loaded"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture untracked)
EOF
touch "${install_root}/third_party/whisper.cpp/untracked.txt"
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
assert_dir "${install_root}/third_party/whisper.cpp"
assert_dir "${app_root}"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture sudo-fail)
EOF
export WHISPER_FIXTURE_SUDO_FAIL=1
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
unset WHISPER_FIXTURE_SUDO_FAIL
assert_dir "${app_root}"
assert_file "${state}/launchd.loaded"
assert_file "${state}/firewall"

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture lingering-gateway)
EOF
export WHISPER_FIXTURE_PS_AFTER_BOOTOUT="${app_root}/bin/whisper-on-demand-gateway --gateway-port 8080 --backend-port 18080 --inference-path /v1/audio/transcriptions --model ${app_root}/runtime/models/ggml-large-v3-turbo.bin"
run_uninstall_expect_fail "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
unset WHISPER_FIXTURE_PS_AFTER_BOOTOUT
assert_dir "${app_root}"
assert_file "${home}/Library/LaunchAgents/com.local.whisper-on-demand-gateway.plist"
assert_equal "$(wc -l <"${state}/firewall" | tr -d ' ')" '4'

IFS='|' read -r fixture install_root app_root home state bin <<EOF
$(make_fixture delete)
EOF
run_uninstall "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes
assert_absent "${install_root}/build"
assert_absent "${install_root}/var"
assert_absent "${install_root}/third_party/whisper.cpp"
assert_absent "${app_root}"
assert_absent "${home}/Library/LaunchAgents/com.local.whisper-on-demand-gateway.plist"
assert_absent "${home}/Library/Logs/whisper-custom-host"
assert_absent "${state}/launchd.loaded"
assert_file "${install_root}/.env"
assert_file "${install_root}/models/root-model.bin"
assert_file "${install_root}/keep-untracked.txt"
assert_equal "$(cat "${state}/firewall")" ''
run_uninstall "${install_root}/config.env" "${home}" "${state}" "${bin}" --yes

printf 'uninstall fixture tests passed\n'
