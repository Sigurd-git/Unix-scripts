#!/usr/bin/env bash

# Reproduce a Codex control link whose /tmp target exists only in the container.
set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d /tmp/rvnc-app-server.XXXXXX)"
trap 'rm -rf "${fixture_directory}"' EXIT

awk '/^instance_process_belongs_to_job\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "${repository_directory}/remote_vnc/start_opencodex.sh" \
    > "${fixture_directory}/probe.sh"
awk '/^read_json_integer\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "${repository_directory}/remote_vnc/start_opencodex.sh" \
    >> "${fixture_directory}/probe.sh"
awk '/^instance_codex_app_server_is_running\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "${repository_directory}/remote_vnc/start_opencodex.sh" \
    >> "${fixture_directory}/probe.sh"
awk '/^find_running_app_server\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "${repository_directory}/remote_vnc/start_opencodex.sh" \
    >> "${fixture_directory}/probe.sh"
[[ -s "${fixture_directory}/probe.sh" ]]

export TEST_CGROUP_FILE="${fixture_directory}/cgroup"
export TEST_CONTAINER_SOCKET="${fixture_directory}/app-server-control.sock"
export TEST_REAL_SOCKET="${fixture_directory}/daemon.sock"
export TEST_CMDLINE_FILE="${fixture_directory}/cmdline"
printf '0::/job_900001/step_batch/\n' > "${TEST_CGROUP_FILE}"
printf 'codex\0app-server\0daemon\0' > "${TEST_CMDLINE_FILE}"
ln -s /tmp/codex-daemon-0/container-only.sock "${TEST_CONTAINER_SOCKET}"
[[ -L "${TEST_CONTAINER_SOCKET}" && ! -S "${TEST_CONTAINER_SOCKET}" ]]

perl -MIO::Socket::UNIX -MSocket=SOCK_STREAM -e '
    IO::Socket::UNIX->new(Local => $ARGV[0], Type => SOCK_STREAM, Listen => 1)
        or die "Could not create fixture socket: $!\n";
' "${TEST_REAL_SOCKET}"
[[ -S "${TEST_REAL_SOCKET}" ]]

cat > "${fixture_directory}/apptainer" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == exec && "$2" == --cleanenv && "$3" == instance://fixture ]]
shift 3
[[ "$1" == /bin/bash && "$2" == -c && "$4" == -- ]]
probe_script="$3"
shift 4
[[ "${3:-}" == "${TEST_CONTAINER_SOCKET}" || -z "${3:-}" ]]
probe_script="${probe_script//\/proc\/\$\{process_id\}\/cgroup/${TEST_CGROUP_FILE}}"
probe_script="${probe_script//\/proc\/\$1\/cmdline/${TEST_CMDLINE_FILE}}"
if [[ -n "${3:-}" ]]; then
    set -- "$1" "$2" "${TEST_REAL_SOCKET}"
fi
exec /bin/bash -c "${probe_script}" -- "$@"
MOCK
chmod +x "${fixture_directory}/apptainer"

# The mock maps the container-only socket and /proc cgroup into the fixture.
source "${fixture_directory}/probe.sh"
apptainer_executable="${fixture_directory}/apptainer"
instance_exec_options=(exec --cleanenv)
service_instance_uri=instance://fixture
job_id=900001
timeout() { shift; "$@"; }
run_in_container() {
    "${apptainer_executable}" "${instance_exec_options[@]}" \
        "${service_instance_uri}" "$@"
}

instance_process_belongs_to_job "$$" "${TEST_CONTAINER_SOCKET}"
instance_process_belongs_to_job "$$"
app_server_pid_files=(
    "${fixture_directory}/app-server.pid"
    "${fixture_directory}/daemon.pid"
)
container_app_server_control_socket="${TEST_CONTAINER_SOCKET}"
printf '{"pid":%s}\n' "$$" > "${app_server_pid_files[1]}"
find_running_app_server
[[ "${app_server_process_id}" == "$$" ]]
mv "${app_server_pid_files[1]}" "${app_server_pid_files[0]}"
find_running_app_server
[[ "${app_server_process_id}" == "$$" ]]
printf 'sleep\0infinity\0' > "${TEST_CMDLINE_FILE}"
if find_running_app_server; then
    printf 'A process that is not an app server was reported ready.\n' >&2
    exit 1
fi
printf 'codex\0app-server\0daemon\0' > "${TEST_CMDLINE_FILE}"
rm "${TEST_REAL_SOCKET}"
if instance_process_belongs_to_job "$$" "${TEST_CONTAINER_SOCKET}"; then
    printf 'Missing container socket was reported ready.\n' >&2
    exit 1
fi
printf '0::/job_900002/step_batch/\n' > "${TEST_CGROUP_FILE}"
if instance_process_belongs_to_job "$$"; then
    printf 'Process from another Slurm job was reported ready.\n' >&2
    exit 1
fi
printf 'PASS: app-server readiness probes its socket and process inside the container\n'
