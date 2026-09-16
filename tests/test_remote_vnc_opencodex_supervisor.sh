#!/usr/bin/env bash

# Exercise the independent OpenCodex supervisor with an isolated fake daemon.
set -Eeuo pipefail

command -v flock >/dev/null || exit 0
command -v timeout >/dev/null || exit 0

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
cleanup() {
    if [[ -s "${fixture_directory}/supervisor.pid" ]]; then
        supervisor_process_id="$(head -n 1 "${fixture_directory}/supervisor.pid" || true)"
        if [[ "${supervisor_process_id}" =~ ^[0-9]+$ ]]; then
            kill -TERM "${supervisor_process_id}" 2>/dev/null || true
            sleep 0.2
        fi
    fi
    if [[ -s "${fixture_directory}/ocx.pid" ]]; then
        opencodex_process_id="$(head -n 1 "${fixture_directory}/ocx.pid" || true)"
        if [[ "${opencodex_process_id}" =~ ^[0-9]+$ ]]; then
            kill -KILL "${opencodex_process_id}" 2>/dev/null || true
        fi
    fi
    rm -rf "${fixture_directory}"
}
trap cleanup EXIT

cat > "${fixture_directory}/ocx" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

pid_file="${TEST_OCX_PID_FILE}"
start_count_file="${TEST_OCX_START_COUNT_FILE}"
start_failures="${TEST_OCX_FAIL_STARTS:-0}"
# The supervisor inherits its environment once, so a test that flips behaviour
# after startup has to publish the change through a file it re-reads.
pending_ready=false
[[ ! -s "${TEST_OCX_PENDING_FLAG_FILE}" ]] ||
    pending_ready="$(head -n 1 "${TEST_OCX_PENDING_FLAG_FILE}")"

case "${1:-}" in
    start)
        start_count=0
        [[ ! -s "${start_count_file}" ]] || start_count="$(cat "${start_count_file}")"
        start_count=$((start_count + 1))
        printf '%s\n' "${start_count}" > "${start_count_file}"
        if (( start_count <= start_failures )); then
            exit 41
        fi
        (
            trap '[[ "$(cat "${pid_file}" 2>/dev/null || true)" == "$$" ]] && rm -f "${pid_file}"; exit 0' TERM INT
            while :; do
                sleep 0.1
            done
        ) &
        printf '%s\n' "$!" > "${pid_file}"
        exit 0
        ;;
    ready)
        # Mirror the real CLI surface: `--json` prints
        # {"ready","status","pid","port"} and `--wait` blocks until the proxy
        # answers or the supplied timeout expires.
        shift
        wait_requested=false
        wait_timeout=0
        while (( $# > 0 )); do
            case "$1" in
                --wait) wait_requested=true ;;
                --timeout) wait_timeout="${2:-0}"; shift ;;
            esac
            shift
        done
        if [[ "${TEST_OCX_HANG_READY:-false}" == true ]]; then
            sleep 30
        fi
        if [[ "${wait_requested}" == true ]]; then
            wait_deadline=$((SECONDS + wait_timeout))
            while (( SECONDS < wait_deadline )); do
                [[ "${pending_ready}" == true ]] || break
                sleep 0.1
                [[ ! -s "${TEST_OCX_PENDING_FLAG_FILE}" ]] ||
                    pending_ready="$(head -n 1 "${TEST_OCX_PENDING_FLAG_FILE}")"
            done
        fi
        if [[ -s "${pid_file}" ]] &&
           kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
            if [[ "${pending_ready}" == true ]]; then
                printf '{"ready":false,"status":"pending","pid":%s,"port":10100}\n' \
                    "$(cat "${pid_file}")"
                exit 1
            fi
            printf '{"ready":true,"status":"ready","pid":%s,"port":10100}\n' \
                "$(cat "${pid_file}")"
            exit 0
        fi
        printf '{"ready":false,"status":"unreachable","pid":null,"port":null}\n'
        exit 1
        ;;
    stop)
        if [[ -s "${pid_file}" ]]; then
            opencodex_process_id="$(cat "${pid_file}")"
            kill -TERM "${opencodex_process_id}" 2>/dev/null || true
            rm -f "${pid_file}"
        fi
        exit 0
        ;;
    *)
        exit 2
        ;;
esac
MOCK
chmod 700 "${fixture_directory}/ocx"

export TEST_OCX_PID_FILE="${fixture_directory}/ocx.pid"
export TEST_OCX_START_COUNT_FILE="${fixture_directory}/ocx-start-count"
export TEST_OCX_PENDING_FLAG_FILE="${fixture_directory}/ocx-pending-ready"
export TEST_OCX_FAIL_STARTS=1
printf 'true\n' > "${TEST_OCX_PENDING_FLAG_FILE}"

supervisor="${repository_directory}/remote_vnc/opencodex_supervisor.sh"
cp "${repository_directory}/remote_vnc/opencodex_command.sh" \
    "${fixture_directory}/opencodex_command.sh"
chmod 700 "${fixture_directory}/opencodex_command.sh"
managed_codex="${fixture_directory}/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "${managed_codex}"
chmod 700 "${managed_codex}"
log_file="${fixture_directory}/opencodex.log"
supervisor_log_file="${fixture_directory}/supervisor.log"
control_directory="${fixture_directory}/control"
state_file="${fixture_directory}/supervisor.env"
pid_file="${fixture_directory}/supervisor.pid"

read_state() {
    local requested_key="$1"
    awk -F= -v requested_key="${requested_key}" \
        '$1 == requested_key { sub(/^[^=]*=/, ""); print; exit }' \
        "${state_file}"
}

wait_for_state() {
    local expected_status="$1"
    local deadline=$((SECONDS + ${2:-15}))
    local actual_status

    while (( SECONDS < deadline )); do
        actual_status="$(read_state STATUS 2>/dev/null || true)"
        [[ "${actual_status}" == "${expected_status}" ]] && return 0
        sleep 0.1
    done
    printf 'Timed out waiting for supervisor state %s.\n' "${expected_status}" >&2
    cat "${state_file}" >&2 2>/dev/null || true
    cat "${supervisor_log_file}" >&2 2>/dev/null || true
    return 1
}

"${supervisor}" "${fixture_directory}/ocx" "${log_file}" \
    "${supervisor_log_file}" "${control_directory}" "${state_file}" \
    "${pid_file}" 3 1 1 2 2 10 1 &
supervisor_process_id=$!

# A proxy that only ever answers "pending" is not serving, so the supervisor must
# never publish it as running: start_opencodex.sh would hand callers a dead port.
wait_for_state backoff
[[ "$(read_state PID)" == '' ]]
[[ "$(read_state PORT)" == '' ]]
printf 'false\n' > "${TEST_OCX_PENDING_FLAG_FILE}"
wait_for_state running
first_opencodex_process_id="$(read_state PID)"
[[ "${first_opencodex_process_id}" =~ ^[0-9]+$ ]]
[[ "$(read_state PORT)" == 10100 ]]
[[ "$(read_state READINESS_STATUS)" == ready ]]
printf 'PASS: a pending proxy is never published as running\n'
kill -KILL "${first_opencodex_process_id}"

second_opencodex_process_id=""
deadline=$((SECONDS + 15))
while (( SECONDS < deadline )); do
    if [[ "$(read_state STATUS 2>/dev/null || true)" == running ]]; then
        candidate_process_id="$(read_state PID)"
        if [[ "${candidate_process_id}" =~ ^[0-9]+$ &&
              "${candidate_process_id}" != "${first_opencodex_process_id}" ]]; then
            second_opencodex_process_id="${candidate_process_id}"
            break
        fi
    fi
    sleep 0.1
done
[[ "${second_opencodex_process_id}" =~ ^[0-9]+$ ]]
[[ "$(read_state TOTAL_RESTARTS)" -ge 2 ]]
grep -q 'is no longer running' "${supervisor_log_file}"
grep -q 'retry' "${supervisor_log_file}"
printf 'PASS: unexpected OpenCodex exit triggers bounded exponential restart\n'

run_supervisor_command() {
    env \
        BH_ENV_OPENCODEX_SUPERVISOR_LOG="${supervisor_log_file}" \
        BH_ENV_OPENCODEX_SUPERVISOR_STATE="${state_file}" \
        BH_ENV_OPENCODEX_SUPERVISOR_CONTROL="${control_directory}" \
        BH_ENV_OPENCODEX_SUPERVISOR_PID_FILE="${pid_file}" \
        BH_ENV_OPENCODEX_SUPERVISOR_STARTUP_TIMEOUT=5 \
        "${fixture_directory}/opencodex_command.sh" \
        "${fixture_directory}/ocx" "${managed_codex}" "${log_file}" "$@"
}

run_supervisor_command stop
wait_for_state stopped
[[ "$(read_state DESIRED_STATE)" == stopped ]]
[[ ! -s "${fixture_directory}/ocx.pid" ]]
run_supervisor_command start
wait_for_state running

kill -TERM "${supervisor_process_id}"
wait "${supervisor_process_id}" || true
[[ "$(read_state STATUS)" == stopped ]]
grep -q 'Supervisor stopped' "${supervisor_log_file}"
printf 'PASS: supervisor accepts independent stop/start control and shuts down cleanly\n'

# A hung readiness command must not block the supervisor's restart loop.
rm -f "${state_file}" "${pid_file}" "${fixture_directory}/ocx.pid"
: > "${supervisor_log_file}"
export TEST_OCX_HANG_READY=true
"${supervisor}" "${fixture_directory}/ocx" "${log_file}" \
    "${supervisor_log_file}" "${control_directory}" "${state_file}" \
    "${pid_file}" 3 1 1 2 2 10 1 &
supervisor_process_id=$!
# Each hung probe burns the supervisor's 10s floor, so the first failed start
# needs the adopt probe, the start, and the in-loop probe to expire.
wait_for_state backoff 60
grep -q 'did not become ready within 3s' "${supervisor_log_file}"
kill -TERM "${supervisor_process_id}"
wait "${supervisor_process_id}" || true
unset TEST_OCX_HANG_READY
printf 'PASS: hung readiness probes are forcibly bounded\n'
