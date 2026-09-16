#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

managed_opencodex_executable="${1:?managed OpenCodex executable is required}"
opencodex_log_file="${2:?OpenCodex log file is required}"
supervisor_log_file="${3:?OpenCodex supervisor log file is required}"
control_directory="${4:?OpenCodex supervisor control directory is required}"
supervisor_state_file="${5:?OpenCodex supervisor state file is required}"
supervisor_pid_file="${6:?OpenCodex supervisor PID file is required}"
startup_timeout_seconds="${7:-600}"
poll_interval_seconds="${8:-2}"
initial_backoff_seconds="${9:-2}"
maximum_backoff_seconds="${10:-60}"
stable_runtime_seconds="${11:-60}"
readiness_probe_timeout_seconds="${12:-30}"
readiness_refresh_seconds="${13:-30}"
listen_port="${BH_ENV_OPENCODEX_PORT:-10100}"

# `ocx` is a Node launcher that spawns Bun to run the CLI from shared storage, so
# a cold probe costs seconds before it can answer. Bounding it at a couple of
# seconds reports "not ready" for a healthy proxy and starves the restart loop.
(( readiness_probe_timeout_seconds >= 10 )) || readiness_probe_timeout_seconds=10
if ! [[ "${listen_port}" =~ ^[1-9][0-9]*$ ]] ||
   (( listen_port > 65535 )); then
    listen_port=10100
fi

# The OpenCodex CLI refuses `ready --wait --timeout` above its own
# MAX_READY_WAIT_TIMEOUT_SECONDS, so every blocking wait is clamped to it.
maximum_ready_wait_seconds=300

for timeout_value in \
    "${startup_timeout_seconds}" "${poll_interval_seconds}" \
    "${initial_backoff_seconds}" "${maximum_backoff_seconds}" \
    "${stable_runtime_seconds}" "${readiness_probe_timeout_seconds}" \
    "${readiness_refresh_seconds}"; do
    [[ "${timeout_value}" =~ ^[1-9][0-9]*$ ]] || {
        printf 'OpenCodex supervisor timing values must be positive integers.\n' >&2
        exit 2
    }
done
(( initial_backoff_seconds <= maximum_backoff_seconds )) || {
    printf 'OpenCodex supervisor initial backoff must not exceed its maximum.\n' >&2
    exit 2
}
for required_command in date dirname flock grep head kill mkdir mv nohup rm sed sleep timeout; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        printf 'OpenCodex supervisor command is unavailable: %s\n' \
            "${required_command}" >&2
        exit 2
    }
done
[[ -x "${managed_opencodex_executable}" ]] || {
    printf 'Managed OpenCodex executable is not executable: %s\n' \
        "${managed_opencodex_executable}" >&2
    exit 2
}

request_file="${control_directory}/request"
request_lock_file="${control_directory}/request.lock"
supervisor_lock_file="${control_directory}/supervisor.lock"

mkdir -p "${control_directory}" "$(dirname "${supervisor_state_file}")" \
    "$(dirname "${supervisor_pid_file}")" \
    "$(dirname "${opencodex_log_file}")" "$(dirname "${supervisor_log_file}")"
chmod 700 "${control_directory}"
touch "${opencodex_log_file}" "${supervisor_log_file}"
chmod 600 "${opencodex_log_file}" "${supervisor_log_file}"

exec 9> "${supervisor_lock_file}"
flock -n 9 || {
    printf 'Another OpenCodex supervisor is already running for %s.\n' \
        "${control_directory}" >&2
    exit 17
}

write_pid_file() {
    local temporary_pid_file="${supervisor_pid_file}.tmp.$$"

    printf '%s\n' "$$" > "${temporary_pid_file}"
    chmod 600 "${temporary_pid_file}"
    mv "${temporary_pid_file}" "${supervisor_pid_file}"
}

log_message() {
    local message="$1"

    printf '[remote-vnc ocx-supervisor] %s %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${message}" \
        >> "${supervisor_log_file}"
}

write_state() {
    local status_value="$1"
    local temporary_state_file="${supervisor_state_file}.tmp.$$"

    {
        printf 'STATUS=%s\n' "${status_value}"
        printf 'SUPERVISOR_PID=%s\n' "$$"
        printf 'PID=%s\n' "${opencodex_process_id}"
        printf 'LAUNCHER_PID=%s\n' "${opencodex_launcher_process_id}"
        printf 'PORT=%s\n' "${opencodex_port}"
        printf 'READINESS_STATUS=%s\n' "${opencodex_readiness_status}"
        printf 'DESIRED_STATE=%s\n' "${desired_state}"
        printf 'LAST_EXIT_STATUS=%s\n' "${last_exit_status}"
        printf 'CONSECUTIVE_FAILURES=%s\n' "${consecutive_failure_count}"
        printf 'TOTAL_RESTARTS=%s\n' "${total_restart_count}"
        printf 'NEXT_RESTART_EPOCH=%s\n' "${next_restart_epoch}"
        printf 'LAST_REQUEST_ID=%s\n' "${last_request_id}"
        printf 'LAST_REQUEST_STATUS=%s\n' "${last_request_status}"
        printf 'SUPERVISOR_LOG=%s\n' "${supervisor_log_file}"
        printf 'OPENCODEX_LOG=%s\n' "${opencodex_log_file}"
        printf 'UPDATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${temporary_state_file}"
    chmod 600 "${temporary_state_file}"
    mv "${temporary_state_file}" "${supervisor_state_file}"
}

process_is_running() {
    local process_id="$1"

    [[ "${process_id}" =~ ^[1-9][0-9]*$ ]] &&
        kill -0 "${process_id}" 2>/dev/null
}

control_request_command=""
control_request_id=""
read_control_request() {
    local request_value=""
    local request_identifier=""

    if [[ -s "${request_file}" ]]; then
        request_value="$(head -n 1 "${request_file}")"
        request_identifier="$(sed -n '2p' "${request_file}")"
        rm -f "${request_file}"
    fi
    control_request_command="${request_value}"
    control_request_id="${request_identifier}"
}

read_json_integer() {
    local json_record="$1"
    local field_name="$2"

    sed -n \
        "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        <<< "${json_record}" | head -n 1
}

read_json_string() {
    local json_record="$1"
    local field_name="$2"

    sed -n \
        "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
        <<< "${json_record}" | head -n 1
}

read_ready_record() {
    timeout -k 5 "${readiness_probe_timeout_seconds}" \
        "${managed_opencodex_executable}" ready --json 2>/dev/null || true
}

# Block on the CLI's own readiness contract instead of re-paying the launcher's
# cold-start cost once per second. The caller keeps the overall budget and stays
# responsive to a start command that dies while the wait is in flight.
await_ready_record() {
    local remaining_seconds="$1"
    local wait_seconds="${remaining_seconds}"

    (( wait_seconds > 0 )) || return 1
    (( wait_seconds <= maximum_ready_wait_seconds )) ||
        wait_seconds="${maximum_ready_wait_seconds}"
    timeout -k 5 \
        $(( wait_seconds + readiness_probe_timeout_seconds )) \
        "${managed_opencodex_executable}" ready --wait \
        --timeout "${wait_seconds}" --json >/dev/null 2>&1 || true
}

refresh_process_state() {
    local ready_record
    local candidate_process_id
    local candidate_port
    local candidate_readiness_status

    ready_record="$(read_ready_record)"
    candidate_readiness_status="$(read_json_string "${ready_record}" status)"
    # `ocx ready --json` reports {"ready":bool,"status":...,"pid":...,"port":...}.
    # Only a serving proxy may be published as running: "pending" means startup is
    # still in flight, and treating it as running hands callers a dead port.
    if [[ "${candidate_readiness_status}" != 'ready' ]] &&
       ! grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' <<< "${ready_record}"; then
        return 1
    fi
    candidate_process_id="$(read_json_integer "${ready_record}" pid)"
    candidate_port="$(read_json_integer "${ready_record}" port)"
    [[ "${candidate_port}" =~ ^[1-9][0-9]*$ ]] || return 1
    process_is_running "${candidate_process_id}" || return 1

    opencodex_process_id="${candidate_process_id}"
    opencodex_port="${candidate_port}"
    opencodex_readiness_status="${candidate_readiness_status:-ready}"
    return 0
}

clear_process_state() {
    opencodex_process_id=""
    opencodex_port=""
    opencodex_readiness_status=""
}

# `ocx start` stays in the foreground: the launcher this supervisor spawns is the
# service's lifetime, while the PID inside the ready record belongs to the CLI
# runtime it execs. Terminating the launcher therefore stops OpenCodex, and the
# launcher is the process whose liveness the restart loop must follow.
terminate_launcher_process() {
    local wait_deadline

    process_is_running "${opencodex_launcher_process_id}" || {
        opencodex_launcher_process_id=""
        return 0
    }
    kill -TERM "${opencodex_launcher_process_id}" 2>/dev/null || true
    wait_deadline=$((SECONDS + 15))
    while process_is_running "${opencodex_launcher_process_id}" &&
          (( SECONDS < wait_deadline )); do
        sleep 1
    done
    if process_is_running "${opencodex_launcher_process_id}"; then
        log_message "OpenCodex launcher PID ${opencodex_launcher_process_id} did not exit; sending SIGKILL."
        kill -KILL "${opencodex_launcher_process_id}" 2>/dev/null || true
    fi
    wait "${opencodex_launcher_process_id}" 2>/dev/null || true
    opencodex_launcher_process_id=""
}

stop_managed_opencodex() {
    local stop_status=0
    local wait_deadline

    if process_is_running "${opencodex_process_id}"; then
        log_message "Stopping OpenCodex PID ${opencodex_process_id}."
    else
        log_message 'Stopping OpenCodex after a stale or missing process record.'
    fi

    timeout -k 5 30 "${managed_opencodex_executable}" stop \
        >> "${supervisor_log_file}" 2>&1 || stop_status=$?
    if (( stop_status != 0 )); then
        log_message "OpenCodex stop command returned ${stop_status}."
    fi

    wait_deadline=$((SECONDS + 30))
    while process_is_running "${opencodex_process_id}" &&
          (( SECONDS < wait_deadline )); do
        sleep 1
    done
    if process_is_running "${opencodex_process_id}"; then
        log_message "OpenCodex PID ${opencodex_process_id} did not stop; sending SIGTERM."
        kill -TERM "${opencodex_process_id}" 2>/dev/null || true
    fi
    terminate_launcher_process
    clear_process_state
    running_since_epoch=0
    return 0
}

stop_start_command() {
    local start_exit_status=0
    local startup_deadline

    # A supervisor restart must adopt a still-running daemon instead of
    # launching a second OpenCodex process.
    if refresh_process_state; then
        return 0
    fi

    supervisor_status='starting'
    write_state "${supervisor_status}"
    log_message "Starting OpenCodex with a ${startup_timeout_seconds}s readiness timeout on port ${listen_port}."
    nohup "${managed_opencodex_executable}" start --port "${listen_port}" </dev/null \
        >> "${opencodex_log_file}" 2>&1 &
    opencodex_launcher_process_id=$!
    startup_deadline=$((SECONDS + startup_timeout_seconds))

    while (( SECONDS < startup_deadline )); do
        if refresh_process_state; then
            return 0
        fi
        if [[ -n "${opencodex_launcher_process_id}" ]] &&
           ! process_is_running "${opencodex_launcher_process_id}"; then
            wait "${opencodex_launcher_process_id}" || start_exit_status=$?
            opencodex_launcher_process_id=""
            if (( start_exit_status != 0 )); then
                log_message "OpenCodex start command exited with status ${start_exit_status}."
                return "${start_exit_status}"
            fi
            # A build that daemonizes instead of staying attached exits cleanly
            # before the ready record appears; keep waiting for the proxy.
        fi
        await_ready_record $((startup_deadline - SECONDS))
    done

    log_message "OpenCodex did not become ready within ${startup_timeout_seconds}s."
    terminate_launcher_process
    return 124
}

calculate_backoff_seconds() {
    local backoff_seconds="${initial_backoff_seconds}"
    local failure_index

    for ((failure_index = 1;
          failure_index < consecutive_failure_count;
          failure_index++)); do
        if (( backoff_seconds >= maximum_backoff_seconds )); then
            break
        fi
        backoff_seconds=$((backoff_seconds * 2))
        if (( backoff_seconds > maximum_backoff_seconds )); then
            backoff_seconds="${maximum_backoff_seconds}"
        fi
    done
    printf '%s\n' "${backoff_seconds}"
}

register_failed_attempt() {
    local backoff_seconds
    local now_epoch

    now_epoch="$(date +%s)"
    if (( running_since_epoch > 0 &&
          now_epoch - running_since_epoch >= stable_runtime_seconds )); then
        consecutive_failure_count=0
    fi
    consecutive_failure_count=$((consecutive_failure_count + 1))
    total_restart_count=$((total_restart_count + 1))
    backoff_seconds="$(calculate_backoff_seconds)"
    next_restart_epoch=$((now_epoch + backoff_seconds))
    supervisor_status='backoff'
    if [[ -n "${pending_request_id}" ]]; then
        last_request_id="${pending_request_id}"
        last_request_status='failed'
        pending_request_id=""
    fi
    write_state "${supervisor_status}"
    log_message "OpenCodex failed; retry ${consecutive_failure_count} in ${backoff_seconds}s (last_exit=${last_exit_status:-unknown})."
    running_since_epoch=0
}

handle_request() {
    local request_value="$1"
    local request_id="${2:-}"

    case "${request_value}" in
        '') ;;
        start)
            desired_state='running'
            next_restart_epoch=0
            consecutive_failure_count=0
            log_message 'Received start request.'
            if process_is_running "${opencodex_process_id}" &&
               [[ "${supervisor_status}" == 'running' ]]; then
                last_request_id="${request_id}"
                last_request_status='running'
                write_state "${supervisor_status}"
            else
                pending_request_id="${request_id}"
            fi
            ;;
        stop)
            desired_state='stopped'
            next_restart_epoch=0
            log_message 'Received stop request.'
            stop_managed_opencodex
            supervisor_status='stopped'
            pending_request_id=""
            last_request_id="${request_id}"
            last_request_status='stopped'
            write_state "${supervisor_status}"
            ;;
        restart)
            desired_state='running'
            next_restart_epoch=0
            consecutive_failure_count=0
            log_message 'Received restart request.'
            stop_managed_opencodex
            supervisor_status='stopped'
            pending_request_id="${request_id}"
            write_state "${supervisor_status}"
            ;;
        *)
            log_message "Ignoring unknown supervisor request: ${request_value}."
            ;;
    esac
}

termination_requested=false
on_termination() {
    termination_requested=true
    desired_state='stopped'
}
trap on_termination INT TERM

opencodex_process_id=""
opencodex_launcher_process_id=""
last_readiness_refresh_epoch=0
opencodex_port=""
opencodex_readiness_status=""
desired_state='running'
last_exit_status=""
consecutive_failure_count=0
total_restart_count=0
next_restart_epoch=0
running_since_epoch=0
supervisor_status='starting'
pending_request_id=""
last_request_id=""
last_request_status=""

write_pid_file
write_state "${supervisor_status}"
log_message "Supervisor started with PID $$; automatic restart backoff is ${initial_backoff_seconds}-${maximum_backoff_seconds}s."

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM
    desired_state='stopped'
    if process_is_running "${opencodex_process_id}" ||
       process_is_running "${opencodex_launcher_process_id}"; then
        stop_managed_opencodex || true
    fi
    supervisor_status='stopped'
    write_state "${supervisor_status}"
    rm -f "${supervisor_pid_file}"
    log_message "Supervisor stopped with status ${exit_status}."
    exit "${exit_status}"
}
trap cleanup EXIT

while :; do
    read_control_request
    handle_request "${control_request_command}" "${control_request_id}"

    if [[ "${termination_requested}" == 'true' ]]; then
        desired_state='stopped'
        stop_managed_opencodex
        supervisor_status='stopped'
        write_state "${supervisor_status}"
        break
    fi

    if [[ "${desired_state}" == 'stopped' ]]; then
        if process_is_running "${opencodex_process_id}" ||
           process_is_running "${opencodex_launcher_process_id}"; then
            stop_managed_opencodex
        fi
        if [[ "${supervisor_status}" != 'stopped' ]]; then
            supervisor_status='stopped'
            write_state "${supervisor_status}"
        fi
        sleep "${poll_interval_seconds}"
        continue
    fi

    if process_is_running "${opencodex_launcher_process_id}" ||
       process_is_running "${opencodex_process_id}"; then
        current_epoch="$(date +%s)"
        # Liveness is a cheap signal check every poll, but each readiness probe
        # pays the launcher's cold start, so refresh diagnostics on their own
        # interval instead of once per poll. A temporary probe failure must not
        # turn a live daemon into a restart candidate.
        if (( current_epoch - last_readiness_refresh_epoch >=
              readiness_refresh_seconds )); then
            last_readiness_refresh_epoch="${current_epoch}"
            previous_readiness_status="${opencodex_readiness_status}"
            refresh_process_state || true
            if [[ "${previous_readiness_status}" != "${opencodex_readiness_status}" ]]; then
                write_state "${supervisor_status}"
                log_message "OpenCodex readiness status changed from ${previous_readiness_status:-unknown} to ${opencodex_readiness_status:-unknown}."
            fi
        fi
        if [[ "${supervisor_status}" != 'running' ]]; then
            supervisor_status='running'
            write_state "${supervisor_status}"
            log_message "OpenCodex is running with PID ${opencodex_process_id} on port ${opencodex_port}."
        fi
        if (( running_since_epoch == 0 )); then
            running_since_epoch="${current_epoch}"
        elif (( consecutive_failure_count > 0 &&
                current_epoch - running_since_epoch >= stable_runtime_seconds )); then
            consecutive_failure_count=0
        fi
        sleep "${poll_interval_seconds}"
        continue
    fi

    if [[ -n "${opencodex_process_id}${opencodex_launcher_process_id}" ]]; then
        last_exit_status='process-gone'
        log_message "OpenCodex PID ${opencodex_process_id:-${opencodex_launcher_process_id}} is no longer running."
        terminate_launcher_process
        clear_process_state
        register_failed_attempt
    fi

    current_epoch="$(date +%s)"
    if (( next_restart_epoch > current_epoch )); then
        supervisor_status='backoff'
        sleep_seconds=$((next_restart_epoch - current_epoch))
        if (( sleep_seconds > poll_interval_seconds )); then
            sleep_seconds="${poll_interval_seconds}"
        fi
        sleep "${sleep_seconds}"
        continue
    fi

    next_restart_epoch=0
    last_exit_status=""
    if stop_start_command; then
        running_since_epoch="$(date +%s)"
        supervisor_status='running'
        if [[ -n "${pending_request_id}" ]]; then
            last_request_id="${pending_request_id}"
            last_request_status='running'
            pending_request_id=""
        fi
        write_state "${supervisor_status}"
        if [[ "${opencodex_readiness_status}" == 'ready' ]]; then
            log_message "OpenCodex became ready with PID ${opencodex_process_id} on port ${opencodex_port}."
        else
            log_message "OpenCodex started with readiness status ${opencodex_readiness_status:-unknown}; startup synchronization continues with PID ${opencodex_process_id} on port ${opencodex_port}."
        fi
    else
        last_exit_status=$?
        clear_process_state
        register_failed_attempt
    fi
done
