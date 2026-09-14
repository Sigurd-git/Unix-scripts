#!/usr/bin/env bash

set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
export TEST_SERVICE_COMMAND_LOG="${fixture_directory}/commands"
container_home="${fixture_directory}/home"
environment_home="${container_home}"
release_directory="${fixture_directory}/release"
service_instance_name=fixture-instance
service_instance_uri=instance://fixture-instance
instance_exec_options=(exec --env BH_ENV_SERVICE_INSTANCE=fixture-instance)
managed_codex_executable="${fixture_directory}/codex-real"
managed_opencodex_executable="${fixture_directory}/ocx-real"
opencodex_log_file="${fixture_directory}/ocx.log"
apptainer_executable="${fixture_directory}/apptainer"
mkdir -p "${container_home}/.local/bin"
mkdir -p "${release_directory}"
cp "${repository_directory}/remote_vnc/opencodex_command.sh" "${release_directory}/"
cat > "${release_directory}/update_ai_tools.sh" <<'MOCK'
#!/usr/bin/env bash
printf 'update|%s|%s\n' "${BH_ENV_SERVICE_INSTANCE:-caller}" "$2" >> "${TEST_SERVICE_COMMAND_LOG}"
MOCK
chmod +x "${release_directory}/update_ai_tools.sh"

cat > "${apptainer_executable}" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'instance\n' >> "${TEST_SERVICE_COMMAND_LOG}"
[[ "$1 $2 $3 $4" == 'exec --env BH_ENV_SERVICE_INSTANCE=fixture-instance instance://fixture-instance' ]]
shift 4
export BH_ENV_SERVICE_INSTANCE=fixture-instance BH_ENV_ACTIVE=1
exec "$@"
MOCK
cat > "${container_home}/.local/bin/bluehive-host-shell" <<'MOCK'
#!/usr/bin/env bash
printf 'host\n' >> "${TEST_SERVICE_COMMAND_LOG}"
unset BH_ENV_ACTIVE BH_ENV_SERVICE_INSTANCE
exec bash -c "$1"
MOCK
for executable_path in "${managed_codex_executable}" "${managed_opencodex_executable}"; do
    cat > "${executable_path}" <<'MOCK'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$(basename "$0")" "${BH_ENV_SERVICE_INSTANCE:-caller}" "$*" >> "${TEST_SERVICE_COMMAND_LOG}"
MOCK
    chmod +x "${executable_path}"
done
chmod +x "${apptainer_executable}" "${container_home}/.local/bin/bluehive-host-shell"
awk '/^write_container_wrapper\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "${repository_directory}/remote_vnc/start_opencodex.sh" > "${fixture_directory}/wrapper.sh"
source "${fixture_directory}/wrapper.sh"
write_container_wrapper "${container_home}/.local/bin/ocx" "${managed_opencodex_executable}"
write_container_wrapper "${container_home}/.local/bin/codex" "${managed_codex_executable}"

BH_ENV_ACTIVE=1 "${container_home}/.local/bin/ocx" status 'an argument; $(literal)'
grep -qx 'ocx-real|fixture-instance|status an argument; $(literal)' "${TEST_SERVICE_COMMAND_LOG}"
[[ "$(head -n 2 "${TEST_SERVICE_COMMAND_LOG}")" == $'host\ninstance' ]]
: > "${TEST_SERVICE_COMMAND_LOG}"
BH_ENV_ACTIVE=1 "${container_home}/.local/bin/codex" app-server daemon restart
grep -qx 'codex-real|fixture-instance|app-server daemon restart' "${TEST_SERVICE_COMMAND_LOG}"
: > "${TEST_SERVICE_COMMAND_LOG}"
BH_ENV_ACTIVE=1 "${container_home}/.local/bin/codex" --version
grep -qx 'codex-real|caller|--version' "${TEST_SERVICE_COMMAND_LOG}"
[[ "$(wc -l < "${TEST_SERVICE_COMMAND_LOG}")" -eq 1 ]]
for command_name in ocx codex; do
    : > "${TEST_SERVICE_COMMAND_LOG}"
    BH_ENV_ACTIVE=1 "${container_home}/.local/bin/${command_name}" update
    grep -qx "update|fixture-instance|${command_name}" "${TEST_SERVICE_COMMAND_LOG}"
done
printf 'PASS: container service commands join their instance; ordinary Codex preserves the caller\n'

# This section needs Linux flock/timeout, matching the allocation runtime.
command -v flock >/dev/null || exit 0
export TEST_OCX_PID_FILE="${fixture_directory}/ocx.pid"
cat > "${fixture_directory}/detached-ocx" <<'MOCK'
#!/usr/bin/env bash
set -eu
case "$1" in
    start)
        printf '%s\n' "$$" > "${TEST_OCX_PID_FILE}"
        exec sleep 120
        ;;
    ready)
        if [[ "$*" == 'ready --json' ]]; then
            [[ -s "${TEST_OCX_PID_FILE}" ]] && kill -0 "$(cat "${TEST_OCX_PID_FILE}")" 2>/dev/null
        else
            for ((attempt=0; attempt<100; attempt++)); do
                if [[ -s "${TEST_OCX_PID_FILE}" ]] && kill -0 "$(cat "${TEST_OCX_PID_FILE}")" 2>/dev/null; then exit 0; fi
                sleep 0.02
            done
            exit 1
        fi
        ;;
esac
MOCK
chmod +x "${fixture_directory}/detached-ocx"
cleanup() {
    if [[ -s "${TEST_OCX_PID_FILE}" ]]; then kill "$(cat "${TEST_OCX_PID_FILE}")" 2>/dev/null || true; fi
    rm -rf "${fixture_directory}"
}
trap cleanup EXIT
HOME="${container_home}" "${release_directory}/opencodex_command.sh" \
    "${fixture_directory}/detached-ocx" "${managed_codex_executable}" "${opencodex_log_file}" start
original_process_id="$(cat "${TEST_OCX_PID_FILE}")"
kill -0 "${original_process_id}"
HOME="${container_home}" "${release_directory}/opencodex_command.sh" \
    "${fixture_directory}/detached-ocx" "${managed_codex_executable}" "${opencodex_log_file}" start
[[ "$(cat "${TEST_OCX_PID_FILE}")" == "${original_process_id}" ]]
flock -n "${container_home}/.local/share/remote-vnc/ocx-start.lock" true
printf 'PASS: ocx start survives its caller, repeated starts reuse it, and the child releases the lock\n'
