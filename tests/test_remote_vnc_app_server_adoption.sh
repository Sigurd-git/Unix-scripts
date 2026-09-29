#!/usr/bin/env bash

# A client can replace the app-server process while leaving the managed PID
# record stale. The service must adopt its live socket instead of unlinking it.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
socket_listener_process_id=""
cleanup() {
    if [[ "${socket_listener_process_id}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${socket_listener_process_id}" 2>/dev/null || true
        wait "${socket_listener_process_id}" 2>/dev/null || true
    fi
    rm -rf "${fixture_directory}"
}
trap cleanup EXIT

awk '/^app_server_socket_is_ready\(\)/ {copy=1}
     copy && /^start_codex_app_server \|\| exit 5$/ {exit}
     copy {print}' "${repository_directory}/remote_vnc/start_opencodex.sh" \
    > "${fixture_directory}/recovery.sh"
source "${fixture_directory}/recovery.sh"

nc -lU "${fixture_directory}/live.sock" >/dev/null 2>&1 &
socket_listener_process_id=$!
for _ in {1..30}; do
    [[ -S "${fixture_directory}/live.sock" ]] && break
    sleep 0.1
done
[[ -S "${fixture_directory}/live.sock" ]]

container_codex_home="${fixture_directory}"
mkdir -p "${container_codex_home}/app-server-control"
app_server_control_socket="${container_codex_home}/app-server-control/app-server-control.sock"
ln -s "${fixture_directory}/live.sock" "${app_server_control_socket}"
app_server_pid_file="${fixture_directory}/app-server.pid"
app_server_updater_pid_file="${fixture_directory}/app-server-updater.pid"
app_server_restart_marker="${fixture_directory}/restart-marker"
service_log_file="${fixture_directory}/service.log"
printf '{"pid":999}\n' > "${app_server_pid_file}"
app_server_status=stopped
app_server_process_id=""

read_json_integer() { printf '999'; }
date() { printf 'fixture-date'; }
instance_codex_app_server_is_running() { [[ "$1" == 222 ]]; }
instance_process_cgroup_record() { printf 'fixture-job'; }
write_service_state() { printf '%s\n' "$1" >> "${fixture_directory}/states"; }
export TEST_SOCKET_TARGET="$(readlink -f "${app_server_control_socket}")"
ss() {
    printf 'u_str LISTEN 0 128 %s 123 * 0 users:(("codex",pid=222,fd=3))\n' \
        "${TEST_SOCKET_TARGET}"
}
export -f ss
run_in_container() { "$@"; }

start_codex_app_server
[[ "${app_server_status}" == running && "${app_server_process_id}" == 222 ]]
[[ "${app_server_process_cgroup}" == fixture-job ]]
[[ -L "${app_server_control_socket}" && -s "${app_server_pid_file}" ]]
grep -qx READY "${fixture_directory}/states"
printf 'PASS: stale PID record adopts the live job-owned app server\n'

instance_codex_app_server_is_running() { return 1; }
if start_codex_app_server >"${fixture_directory}/stdout" \
    2>"${fixture_directory}/stderr"; then
    printf 'Foreign socket owner was incorrectly adopted.\n' >&2
    exit 1
fi
grep -q 'outside this job' "${fixture_directory}/stderr"
[[ -L "${app_server_control_socket}" && -s "${app_server_pid_file}" ]]
printf 'PASS: foreign socket owner blocks cleanup of the live endpoint\n'
