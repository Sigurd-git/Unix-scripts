#!/usr/bin/env bash
set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
export BH_ENV_NAME=default SLURM_JOB_ID=900004
export BH_ENV_HOST_HOME="${fixture_directory}/host home"
export BH_ENV_HOST_PERSISTENT_HOME="${fixture_directory}/persistent home"
export BH_ENV_CONTAINER_HOME="${fixture_directory}/container home"
export BH_ENV_HOST_COMMAND="${fixture_directory}/bh-env"
export BH_ENV_HOST_SHELL="${fixture_directory}/host-shell"
export PROXY_TEST_LOG="${fixture_directory}/arguments"
bridge_directory="${BH_ENV_CONTAINER_HOME}/.local/state/remote-vnc/ssh/${SLURM_JOB_ID}"
host_bridge_directory="${BH_ENV_HOST_PERSISTENT_HOME}/.local/state/remote-vnc/ssh/${SLURM_JOB_ID}"
mkdir -p "${bridge_directory}/bin" "${host_bridge_directory}" "${BH_ENV_CONTAINER_HOME}/project with spaces"
cp "${repository_directory}/remote_vnc/container_host_proxy.sh" "${bridge_directory}/bin/container-host-proxy"
for command_name in squeue sq slab custom-tool bh-host; do
    ln -s container-host-proxy "${bridge_directory}/bin/${command_name}"
done
cat > "${BH_ENV_HOST_SHELL}" <<'MOCK'
#!/usr/bin/env bash
exec bash -c "$1"
MOCK
cat > "${host_bridge_directory}/host-command.sh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == --list ]]; then
    printf '%s\n' custom-tool tgz _private act codex 'bad;name'
else
    printf '%s\n' "$@" > "${PROXY_TEST_LOG}"
    cat
    exit "${PROXY_TEST_STATUS:-0}"
fi
MOCK
chmod +x "${BH_ENV_HOST_SHELL}" "${host_bridge_directory}/host-command.sh"
cd "${BH_ENV_CONTAINER_HOME}/project with spaces"
printf 'input data\n' | "${bridge_directory}/bin/custom-tool" \
    "${BH_ENV_CONTAINER_HOME}/input file" --output="${BH_ENV_CONTAINER_HOME}/output file" \
    '/bluehive-home/script name' 'literal $(do-not-run); *' > "${fixture_directory}/output"
grep -qx 'input data' "${fixture_directory}/output"
cat > "${fixture_directory}/expected" <<EXPECTED
${BH_ENV_HOST_PERSISTENT_HOME}/project with spaces
custom-tool
${BH_ENV_HOST_PERSISTENT_HOME}/input file
--output=${BH_ENV_HOST_PERSISTENT_HOME}/output file
${BH_ENV_HOST_HOME}/script name
literal \$(do-not-run); *
EXPECTED
cmp "${fixture_directory}/expected" "${PROXY_TEST_LOG}"
actual_status=0
PROXY_TEST_STATUS=37 "${bridge_directory}/bin/custom-tool" </dev/null || actual_status=$?
[[ "${actual_status}" == 37 ]]
printf 'PASS: host proxy maps cwd and paths, preserves literal arguments, stdin and exit status\n'

"${bridge_directory}/bin/bh-host" --refresh
[[ -L "${bridge_directory}/custom-bin/tgz" ]]
[[ ! -e "${bridge_directory}/custom-bin/act" && ! -e "${bridge_directory}/custom-bin/codex" ]]
[[ ! -e "${bridge_directory}/custom-bin/_private" ]]
"${bridge_directory}/custom-bin/custom-tool" </dev/null
grep -qx custom-tool "${PROXY_TEST_LOG}"
printf 'PASS: custom command discovery adds usable wrappers and excludes shell-local/protected commands\n'

cd "${fixture_directory}"
"${bridge_directory}/bin/sq" </dev/null
[[ "$(head -n 1 "${PROXY_TEST_LOG}")" == "${BH_ENV_HOST_HOME}" ]]
actual_status=0
"${bridge_directory}/bin/custom-tool" </dev/null 2> "${fixture_directory}/error" || actual_status=$?
[[ "${actual_status}" != 0 ]]
grep -q 'current directory is container-only' "${fixture_directory}/error"
printf 'PASS: scheduler queries work from container-only directories; file commands require a shared cwd\n'
