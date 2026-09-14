#!/usr/bin/env bash

# Exercise the production monitor with a virtual clock and job/PID fixtures.
set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
export fixture_directory

awk '/^# The instance belongs to the allocation\./ {copy=1} copy {print}' \
    "${repository_directory}/remote_vnc/start_opencodex.sh" > "${fixture_directory}/monitor.sh"
[[ -s "${fixture_directory}/monitor.sh" ]]

cat > "${fixture_directory}/fixture.sh" <<'FIXTURE'
set -Eeuo pipefail
service_instance_process_id=$$
service_log_file="${fixture_directory}/service.log"
app_server_pid_file="${fixture_directory}/daemon.pid"
opencodex_process_id=101
app_server_process_id=201
opencodex_status=running
app_server_status=running
iteration=0
process_belongs_to_job() { ((iteration < 35)); }
instance_process_belongs_to_job() {
    [[ "${scenario}" != wrong_job && ( "$1" == 102 || "$1" == 202 ) ]]
}
instance_process_cgroup_record() { printf 'fixture-job'; }
read_json_integer() { jq -r --arg key "$2" '.[$key] // empty' <<< "$1" 2>/dev/null || true; }
json_reports_true() { jq -e --arg key "$2" '.[$key] == true' <<< "$1" >/dev/null 2>&1; }
read_opencodex_ready_record() {
    if ((iteration >= 30)) && [[ "${scenario}" != stopped ]]; then
        printf '{"ready":true,"pid":102,"port":10100}\n'
    else
        printf '{"ready":false}\n'
    fi
}
write_service_state() {
    printf '%s|%s|%s|%s|%s\n' "$1" "${opencodex_status}" \
        "${opencodex_process_id}" "${app_server_status}" "${app_server_process_id}" \
        >> "${fixture_directory}/states"
}
sleep() {
    iteration=$((iteration + 1))
    SECONDS=$((SECONDS + $1))
    if ((iteration >= 30)) && [[ "${scenario}" != stopped ]]; then
        printf '{"pid":202}\n' > "${app_server_pid_file}"
    else
        printf '{}\n' > "${app_server_pid_file}"
    fi
    printf '%s\n' "${iteration}" > "${fixture_directory}/last-iteration"
}
source "${fixture_directory}/monitor.sh"
FIXTURE

for scenario in stopped restart wrong_job; do
    : > "${fixture_directory}/states"
    : > "${fixture_directory}/service.log"
    actual_status=0
    scenario="${scenario}" bash "${fixture_directory}/fixture.sh" \
        > "${fixture_directory}/stdout" 2> "${fixture_directory}/stderr" || actual_status=$?
    [[ "${actual_status}" == 6 ]]
    [[ "$(cat "${fixture_directory}/last-iteration")" == 35 ]]
    grep -qx 'READY|stopped||stopped|' "${fixture_directory}/states"
    grep -q 'Apptainer service instance stopped' "${fixture_directory}/stderr"
    if [[ "${scenario}" == restart ]]; then
        grep -qx 'READY|running|102|running|202' "${fixture_directory}/states"
    else
        ! grep -q 'READY|running' "${fixture_directory}/states"
    fi
    printf 'PASS: %s AI services do not end the allocation; monitor follows replacement PIDs\n' "${scenario}"
done

# Even loss of the service supervisor must not tear down the VNC desktop.
awk '/^while kill -0 "\$\{vnc_process_id\}"/ {copy=1} copy {print}' \
    "${repository_directory}/remote_vnc/start_vnc.sh" > "${fixture_directory}/desktop.sh"
(
    environment_mode=mutable
    opencodex_service_process_id=888888
    vnc_process_id=999999
    desktop_iterations=0
    kill() { [[ "$2" == 999999 ]] && ((desktop_iterations < 20)); }
    wait() { [[ "$1" == 999999 ]]; }
    sleep() { desktop_iterations=$((desktop_iterations + 1)); }
    source "${fixture_directory}/desktop.sh"
    [[ "${desktop_iterations}" == 20 ]]
    [[ -z "${opencodex_service_process_id}" ]]
) 2> "${fixture_directory}/desktop.log"
grep -q 'keeping VNC and SSH running' "${fixture_directory}/desktop.log"
printf 'PASS: desktop survives loss of the AI service supervisor\n'
