#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

managed_ocx="${1:?managed OpenCodex executable is required}"
managed_codex="${2:?managed Codex executable is required}"
opencodex_log="${3:?OpenCodex log file is required}"
shift 3

release_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
supervisor_log_file="${BH_ENV_OPENCODEX_SUPERVISOR_LOG:-}"
supervisor_state_file="${BH_ENV_OPENCODEX_SUPERVISOR_STATE:-}"
supervisor_control_directory="${BH_ENV_OPENCODEX_SUPERVISOR_CONTROL:-}"
supervisor_pid_file="${BH_ENV_OPENCODEX_SUPERVISOR_PID_FILE:-}"
supervisor_startup_timeout="${BH_ENV_OPENCODEX_SUPERVISOR_STARTUP_TIMEOUT:-600}"

supervisor_configured() {
    [[ -n "${supervisor_log_file}" &&
       -n "${supervisor_state_file}" &&
       -n "${supervisor_control_directory}" &&
       -n "${supervisor_pid_file}" ]]
}

read_supervisor_state_value() {
    local requested_key="$1"

    [[ -s "${supervisor_state_file}" ]] || return 1
    awk -F= -v requested_key="${requested_key}" '
        $1 == requested_key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "${supervisor_state_file}"
}

supervisor_is_running() {
    local supervisor_process_id

    supervisor_process_id="$(head -n 1 "${supervisor_pid_file}" 2>/dev/null || true)"
    [[ "${supervisor_process_id}" =~ ^[1-9][0-9]*$ ]] &&
        kill -0 "${supervisor_process_id}" 2>/dev/null
}

request_supervisor_command() {
    local request_value="$1"
    local request_id="$(date +%s)-$$-${RANDOM}"
    local request_lock_file="${supervisor_control_directory}/request.lock"
    local temporary_request_file="${supervisor_control_directory}/request.tmp.$$"

    mkdir -p "${supervisor_control_directory}"
    (
        exec 8>"${request_lock_file}"
        flock -w 15 8
        printf '%s\n%s\n' "${request_value}" "${request_id}" > \
            "${temporary_request_file}"
        mv -f "${temporary_request_file}" \
            "${supervisor_control_directory}/request"
    )
    printf '%s\n' "${request_id}"
}

wait_for_supervisor_request() {
    local request_id="$1"
    local desired_status="$2"
    local supervisor_deadline=$((SECONDS + supervisor_startup_timeout))
    local completed_request_id
    local completed_request_status
    local current_status

    while (( SECONDS < supervisor_deadline )); do
        completed_request_id="$(read_supervisor_state_value LAST_REQUEST_ID || true)"
        completed_request_status="$(read_supervisor_state_value LAST_REQUEST_STATUS || true)"
        if [[ "${completed_request_id}" == "${request_id}" &&
              "${completed_request_status}" == "${desired_status}" ]]; then
            return 0
        fi
        if [[ "${completed_request_id}" == "${request_id}" &&
              "${completed_request_status}" == 'failed' ]]; then
            printf 'OpenCodex supervisor failed to complete request %s. Log: %s\n' \
                "${desired_status}" "${supervisor_log_file}" >&2
            return 1
        fi
        supervisor_is_running || break
        sleep 1
    done

    current_status="$(read_supervisor_state_value STATUS || true)"
    printf 'OpenCodex supervisor did not complete request for STATUS=%s (current=%s). Log: %s\n' \
        "${desired_status}" "${current_status:-unknown}" \
        "${supervisor_log_file}" >&2
    return 1
}

run_supervisor_command() {
    local supervisor_command="$1"

    supervisor_is_running || {
        printf 'OpenCodex supervisor is not running. Log: %s\n' \
            "${supervisor_log_file}" >&2
        return 1
    }
    local request_id

    request_id="$(request_supervisor_command "${supervisor_command}")"
    if [[ "${supervisor_command}" == 'stop' ]]; then
        wait_for_supervisor_request "${request_id}" stopped
    else
        wait_for_supervisor_request "${request_id}" running
    fi
}

run_supervised_update() {
    local update_status=0
    local start_status=0

    run_supervisor_command stop || return 1
    if timeout 900 "${release_directory}/update_ai_tools.sh" \
        "${managed_codex}" ocx; then
        update_status=0
    else
        update_status=$?
    fi
    if run_supervisor_command start; then
        start_status=0
    else
        start_status=$?
    fi
    if (( update_status != 0 )); then
        return "${update_status}"
    fi
    return "${start_status}"
}

case "${1:-}" in
    start|stop|restart)
        if supervisor_configured && supervisor_is_running; then
            run_supervisor_command "${1}"
        elif [[ "${1}" == 'start' ]]; then
            # Keep the legacy path usable for older bundles without a supervisor.
            mkdir -p "${HOME}/.local/share/remote-vnc"
            exec 9> "${HOME}/.local/share/remote-vnc/ocx-start.lock"
            flock -w 120 9
            # A cold `ocx` probe pays a Node plus Bun start from shared storage,
            # so a short bound reports "not ready" for a healthy proxy and
            # starts a second one.
            if ! timeout -k 5 30 "${managed_ocx}" ready --json >/dev/null 2>&1; then
                nohup "${managed_ocx}" "$@" </dev/null \
                    >> "${opencodex_log}" 2>&1 9>&- &
            fi
            # The CLI rejects a wait longer than its own 300s maximum.
            timeout -k 5 310 "${managed_ocx}" ready --wait --timeout 300
        else
            exec "${managed_ocx}" "$@"
        fi
        ;;
    update)
        if [[ $# -eq 1 ]] && supervisor_configured &&
           supervisor_is_running; then
            run_supervised_update
        elif [[ $# -eq 1 ]]; then
            exec "${release_directory}/update_ai_tools.sh" \
                "${managed_codex}" ocx
        else
            exec "${managed_ocx}" "$@"
        fi
        ;;
    *)
        exec "${managed_ocx}" "$@"
        ;;
esac
