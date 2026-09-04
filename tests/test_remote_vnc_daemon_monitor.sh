#!/usr/bin/env bash

# Run on Linux: bash tests/test_remote_vnc_daemon_monitor.sh
# Exercise the launcher's actual container command with a live fixture PID.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
export TEST_CODEX_HOME="${fixture_directory}/codex"
export TEST_COMMAND_LOG="${fixture_directory}/commands"
export TEST_DAEMON_PID=$$
mkdir -p "${TEST_CODEX_HOME}/app-server-daemon"
printf '{}\n' > "${TEST_CODEX_HOME}/app-server-daemon/settings.json"

# Only substitute the home path; keep the production command and quoting intact.
awk '
    /^write_service_state "STARTING_CODEX_APP_SERVER"/ {armed=1}
    armed && /^run_in_container \/bin\/bash -c / {copy=1}
    copy && /^    >> / {exit}
    copy {print}
' "${repository_directory}/remote_vnc/start_opencodex.sh" |
    sed -e 's/${CODEX_HOME}/${TEST_CODEX_HOME}/g' -e '$s/\\$//' \
        > "${fixture_directory}/monitor.sh"
[[ -s "${fixture_directory}/monitor.sh" ]]

cat > "${fixture_directory}/codex-command" <<'MOCK_CODEX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_COMMAND_LOG}"
if [[ "$*" == "app-server daemon version" ]]; then
    printf 'Error: timed out waiting for initialize response\n' >&2
    exit 1
fi
MOCK_CODEX
chmod +x "${fixture_directory}/codex-command"

run_in_container() { "$@"; }

# Mock only the Slurm cgroup lookup so the test also runs outside an allocation.
grep() {
    if [[ "$*" == "-Fq /job_900003/step_batch/ /proc/${TEST_DAEMON_PID}/cgroup" ]]; then
        [[ "${TEST_SCENARIO}" != "wrong_job" ]]
    else
        command grep "$@"
    fi
}

# Advance the monitor clock instead of waiting a real minute. In the restart
# case, briefly remove its PID record and then restore the live process.
sleep() {
    SECONDS=$((SECONDS + $1))
    test_iteration=$((${test_iteration:-0} + 1))
    if [[ "${TEST_SCENARIO}" == "restart" ]]; then
        if ((test_iteration == 1)); then
            printf '{}\n' > "${TEST_CODEX_HOME}/app-server-daemon/app-server.pid"
        elif ((test_iteration == 4)); then
            printf '{"pid":%s}\n' "${TEST_DAEMON_PID}" \
                > "${TEST_CODEX_HOME}/app-server-daemon/app-server.pid"
        fi
    fi
    if ((test_iteration >= 20)); then
        exit 98 # Test harness stops a monitor that correctly remains running.
    fi
}
export -f run_in_container grep sleep
export managed_codex_executable="${fixture_directory}/codex-command"
export app_server_restart_marker="${fixture_directory}/restarted"
export job_id=900003

check_monitor() {
    export TEST_SCENARIO="$1"
    local expected_status="$2"
    local actual_status=0
    : > "${TEST_COMMAND_LOG}"
    if [[ "${TEST_SCENARIO}" == "missing" ]]; then
        printf '{}\n' > "${TEST_CODEX_HOME}/app-server-daemon/app-server.pid"
    else
        printf '{"pid":%s}\n' "${TEST_DAEMON_PID}" \
            > "${TEST_CODEX_HOME}/app-server-daemon/app-server.pid"
    fi
    bash "${fixture_directory}/monitor.sh" \
        > "${fixture_directory}/stdout" 2> "${fixture_directory}/stderr" || actual_status=$?
    if [[ "${actual_status}" -ne "${expected_status}" ]]; then
        cat "${fixture_directory}/stderr" >&2
        printf '%s: expected status %s, got %s\n' \
            "${TEST_SCENARIO}" "${expected_status}" "${actual_status}" >&2
        exit 1
    fi
    command grep -qx 'app-server daemon restart' "${TEST_COMMAND_LOG}"
    ! command grep -q 'app-server daemon version' "${TEST_COMMAND_LOG}"
}

check_monitor busy 98
printf 'PASS: live daemon stays monitored without a potentially timing-out RPC query\n'
check_monitor restart 98
command grep -q 'process is running again' "${fixture_directory}/stdout"
printf 'PASS: a temporary missing PID during restart recovers without stopping the desktop\n'
check_monitor missing 1
command grep -q 'after 60 seconds' "${fixture_directory}/stderr"
printf 'PASS: a daemon that remains absent is reported after the restart grace period\n'
check_monitor wrong_job 1
command grep -q 'after 60 seconds' "${fixture_directory}/stderr"
printf 'PASS: a live PID from another Slurm job is not accepted\n'
