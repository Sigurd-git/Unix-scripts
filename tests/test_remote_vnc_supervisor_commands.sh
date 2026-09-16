#!/usr/bin/env bash

# Exercise the container ocx wrapper's supervisor control protocol.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
cleanup() {
    if [[ -n "${supervisor_process_id:-}" ]]; then
        kill "${supervisor_process_id}" 2>/dev/null || true
        wait "${supervisor_process_id}" 2>/dev/null || true
    fi
    if [[ -n "${request_watcher_process_id:-}" ]]; then
        kill "${request_watcher_process_id}" 2>/dev/null || true
        wait "${request_watcher_process_id}" 2>/dev/null || true
    fi
    rm -rf "${fixture_directory}"
}
trap cleanup EXIT

release_directory="${fixture_directory}/release"
mock_binary_directory="${fixture_directory}/bin"
control_directory="${fixture_directory}/control"
state_file="${fixture_directory}/supervisor.env"
supervisor_pid_file="${fixture_directory}/supervisor.pid"
log_file="${fixture_directory}/opencodex.log"
supervisor_log_file="${fixture_directory}/supervisor.log"
event_log="${fixture_directory}/events"
managed_ocx="${fixture_directory}/ocx"
managed_codex="${fixture_directory}/codex"
mkdir -p "${release_directory}" "${mock_binary_directory}" "${control_directory}"
cp "${repository_directory}/remote_vnc/opencodex_command.sh" "${release_directory}/"

cat > "${mock_binary_directory}/flock" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "${mock_binary_directory}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
cat > "${release_directory}/update_ai_tools.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'update:%s\n' "$2" >> "${TEST_SUPERVISOR_COMMAND_EVENT_LOG}"
MOCK
cat > "${managed_ocx}" <<'MOCK'
#!/usr/bin/env bash
printf 'direct:%s\n' "$*" >> "${TEST_SUPERVISOR_COMMAND_EVENT_LOG}"
MOCK
cat > "${managed_codex}" <<'MOCK'
#!/usr/bin/env bash
printf 'codex:%s\n' "$*" >> "${TEST_SUPERVISOR_COMMAND_EVENT_LOG}"
MOCK
chmod 700 "${mock_binary_directory}/flock" "${mock_binary_directory}/timeout" \
    "${release_directory}/update_ai_tools.sh" "${managed_ocx}" "${managed_codex}"

printf 'STATUS=running\n' > "${state_file}"
(sleep 120) &
supervisor_process_id=$!
printf '%s\n' "${supervisor_process_id}" > "${supervisor_pid_file}"
export TEST_SUPERVISOR_COMMAND_EVENT_LOG="${event_log}"

(
    set -Eeuo pipefail
    while kill -0 "${supervisor_process_id}" 2>/dev/null; do
        if [[ -s "${control_directory}/request" ]]; then
            request_value="$(head -n 1 "${control_directory}/request")"
            request_id="$(sed -n '2p' "${control_directory}/request")"
            rm -f "${control_directory}/request"
            printf 'request:%s\n' "${request_value}" >> "${event_log}"
            case "${request_value}" in
                stop)
                    {
                        printf 'STATUS=stopped\n'
                        printf 'LAST_REQUEST_ID=%s\n' "${request_id}"
                        printf 'LAST_REQUEST_STATUS=stopped\n'
                    } > "${state_file}"
                    ;;
                start)
                    {
                        printf 'STATUS=running\n'
                        printf 'LAST_REQUEST_ID=%s\n' "${request_id}"
                        printf 'LAST_REQUEST_STATUS=running\n'
                    } > "${state_file}"
                    ;;
                restart)
                    {
                        printf 'STATUS=running\n'
                        printf 'LAST_REQUEST_ID=%s\n' "${request_id}"
                        printf 'LAST_REQUEST_STATUS=running\n'
                    } > "${state_file}"
                    ;;
            esac
        fi
        sleep 0.02
    done
) &
request_watcher_process_id=$!

run_ocx_command() {
    env \
        PATH="${mock_binary_directory}:${PATH}" \
        BH_ENV_OPENCODEX_SUPERVISOR_LOG="${supervisor_log_file}" \
        BH_ENV_OPENCODEX_SUPERVISOR_STATE="${state_file}" \
        BH_ENV_OPENCODEX_SUPERVISOR_CONTROL="${control_directory}" \
        BH_ENV_OPENCODEX_SUPERVISOR_PID_FILE="${supervisor_pid_file}" \
        BH_ENV_OPENCODEX_SUPERVISOR_STARTUP_TIMEOUT=5 \
        "${release_directory}/opencodex_command.sh" \
        "${managed_ocx}" "${managed_codex}" "${log_file}" "$@"
}

run_ocx_command restart
run_ocx_command stop
run_ocx_command start
run_ocx_command update

expected_events=$'request:restart\nrequest:stop\nrequest:start\nrequest:stop\nupdate:ocx\nrequest:start'
[[ "$(cat "${event_log}")" == "${expected_events}" ]] || {
    printf 'Unexpected supervisor command sequence:\n' >&2
    cat "${event_log}" >&2
    exit 1
}
! grep -q '^direct:' "${event_log}"
printf 'PASS: ocx lifecycle and update commands use the independent supervisor\n'
