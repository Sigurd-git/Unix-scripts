#!/usr/bin/env bash

# Run locally: bash tests/test_remote_vnc_host_shell.sh
# The generated host-shell client and server entry are executed with a local
# SSH fixture. No BlueHive host or container is contacted.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_script="${repository_directory}/remote_vnc/start_vnc.sh"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT

host_home="${fixture_directory}/host home"
persistent_home="${fixture_directory}/persistent home"
container_home="${fixture_directory}/container home"
host_shell_directory="${fixture_directory}/host shell"
session_home="${persistent_home}"
SLURM_JOB_ID=900005
export SLURM_JOB_ID
container_host_shell_directory="${container_home}/.local/state/remote-vnc/host-shell/${SLURM_JOB_ID}"
host_shell_client_directory="${session_home}/.local/state/remote-vnc/host-shell/${SLURM_JOB_ID}"
host_shell_entry_script="${host_shell_directory}/entry.sh"
host_shell_rc_file="${host_shell_directory}/bashrc"
bluehive_shell_client="${container_home}/.local/bin/bluehive-host-shell"
host_path_prefix="/usr/bin:/bin"
host_codex_home="${host_home}/.codex"
matlab_vnc_launcher="${host_home}/matlab-vnc"
matlab_vnc_target="fixture"
display_value=:41
environment_name=default
host_shell_port=44422
current_user="$(id -un)"
mkdir -p "${host_home}" "${persistent_home}" "${container_home}/.local/bin" \
    "${host_shell_directory}" "${fixture_directory}/bin" \
    "${persistent_home}/mapped-only" "${container_home}/mapped-only" \
    "${host_home}/project" \
    "${shared_directory:-${fixture_directory}/shared project}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# Run an actual generator brace block selected by a stable output marker.
extract_generator() {
    local marker="$1"
    local output_file="$2"
    awk -v marker="${marker}" '
        /^\{$/ { block = $0 ORS; active = 1; next }
        active { block = block $0 ORS }
        active && index($0, marker) { selected = 1 }
        active && /^\} > / {
            if (selected) { printf "%s", block; exit }
            block = ""; active = 0; selected = 0
        }
    ' "${source_script}" > "${output_file}"
    [[ -s "${output_file}" ]] || fail "could not extract generator: ${marker}"
}

extract_generator 'export DISPLAY=' "${fixture_directory}/entry-generator.sh"
extract_generator '[[ -r /etc/profile.d/modules.sh ]]' \
    "${fixture_directory}/rc-generator.sh"
extract_generator "cat <<'HOST_SHELL_CLIENT'" \
    "${fixture_directory}/client-generator.sh"

source "${fixture_directory}/entry-generator.sh"
source "${fixture_directory}/rc-generator.sh"
source "${fixture_directory}/client-generator.sh"

# Point the generated client at a local SSH shim. It receives the actual
# remote-command argument, records it, and invokes the generated entry script.
mock_ssh="${fixture_directory}/bin/ssh"
cat > "${mock_ssh}" <<'MOCK_SSH'
#!/usr/bin/env bash
set -Eeuo pipefail
remote_command="${!#}"
printf '%s\n' "${remote_command}" > "${HOST_SHELL_TEST_REMOTE_COMMAND}"
export HOME="${HOST_SHELL_TEST_HOST_HOME}"
if [[ -n "${HOST_SHELL_TEST_HIDE_CONTAINER_PATH:-}" ]]; then
    mv "${HOST_SHELL_TEST_HIDE_CONTAINER_PATH}" "${HOST_SHELL_TEST_HIDDEN_PATH}"
    trap 'mv "${HOST_SHELL_TEST_HIDDEN_PATH}" "${HOST_SHELL_TEST_HIDE_CONTAINER_PATH}"' EXIT
fi
status=0
SSH_ORIGINAL_COMMAND="${remote_command}" /bin/bash "${HOST_SHELL_TEST_ENTRY}" || status=$?
exit "${status}"
MOCK_SSH
chmod +x "${mock_ssh}"
sed "s|/usr/bin/ssh|${mock_ssh}|g" "${bluehive_shell_client}" \
    > "${fixture_directory}/client.sh"
chmod +x "${fixture_directory}/client.sh"

run_client() {
    local label="$1"
    local cwd="$2"
    shift 2
    HOST_SHELL_TEST_REMOTE_COMMAND="${fixture_directory}/${label}.remote" \
    HOST_SHELL_TEST_ENTRY="${host_shell_entry_script}" \
    HOST_SHELL_TEST_HOST_HOME="${host_home}" \
    HOST_SHELL_TEST_HIDE_CONTAINER_PATH="$([[ "${label}" == persistent-alias-fallback ]] && printf '%s' "${container_home}/mapped-only")" \
    HOST_SHELL_TEST_HIDDEN_PATH="${fixture_directory}/hidden-container-path" \
    BH_ENV_HOST_PERSISTENT_HOME="${persistent_home}" \
    BH_ENV_HOST_HOME="${host_home}" \
    HOME="${container_home}" \
    PATH="${fixture_directory}/bin:/usr/bin:/bin" \
        /bin/bash -c 'cd "$1"; PWD="$2"; script="$3"; shift 3; source "$script" "$@"' \
        _ "${fixture_directory}" "${cwd}" "${fixture_directory}/client.sh" "$@"
}

# Test paths include a shared absolute directory and each supported remapping.
shared_directory="${fixture_directory}/shared project"
mkdir -p "${shared_directory}"

# Behavioral cases are exercised by sending a command that reports the
# resulting directory and its positional parameters from the host shell.
command_for() {
    printf 'printf "cwd=%%s\\n" "$PWD"; printf "arg=%%s\\n" %q; IFS= read -r line || true; printf "stdin=%%s\\n" "$line"' \
        'arg with spaces; single'"'"'quote; literal $(touch injection); *'
}
run_command_case() {
    local label="$1"
    local container_path="$2"
    local expected_host_path="$3"
    local expected_status="${4:-0}"
    local output status=0
    local command
    command="$(command_for)"
    output="$(run_client "${label}" "${container_path}" "${command}" </dev/null)" \
        || status=$?
    [[ "${status}" == "${expected_status}" ]] ||
        fail "${label}: expected status ${expected_status}, got ${status}"
    [[ "${output}" == *"cwd=${expected_host_path}"* ]] ||
        fail "${label}: cwd mismatch: ${output}"
    [[ "${output}" == *"arg=arg with spaces; single'quote; literal \$(touch injection); *"* ]] ||
        fail "${label}: command parameters or shell-special text changed: ${output}"
    [[ "${output}" == *'stdin='* ]] || fail "${label}: stdin was not preserved"
    [[ ! -e "${fixture_directory}/injection" ]] || fail "${label}: injection ran"
}

run_command_case shared "${shared_directory}" "${shared_directory}"
run_command_case persistent-direct "${container_home}/mapped-only" \
    "${container_home}/mapped-only"
run_command_case persistent-alias-fallback "${container_home}/mapped-only" \
    "${persistent_home}/mapped-only"
run_command_case bluehive-home /bluehive-home/project \
    "${host_home}/project"
run_command_case host-prefix "/host${shared_directory}" "${shared_directory}"
run_command_case container-only "${container_home}/private" "${host_home}"

# The client's cwd encoding must also remain safe with spaces, single quotes,
# substitutions, globs, and separators in the path itself.
special_directory="${shared_directory}/space ' quote \$(touch path-injection) ; *"
mkdir -p "${special_directory}"
run_command_case special-cwd "${special_directory}" "${special_directory}"
[[ ! -e "${shared_directory}/path-injection" ]] ||
    fail 'cwd text triggered shell injection'

# Ensure the generated client keeps stdin available to the remote command.
stdin_command='IFS= read -r line || true; printf "stdin=<%s>\\n" "$line"'
stdin_output="$(printf 'input with spaces\n' | run_client stdin \
    "${shared_directory}" "${stdin_command}")"
[[ "${stdin_output}" == *'stdin=<input with spaces>'* ]] ||
    fail 'stdin content was not forwarded'

# Interactive no-argument mode loads the generated rc file and changes cwd.
interactive_rc="${host_shell_rc_file}"
interactive_cwd_file="${fixture_directory}/interactive-cwd"
printf 'printf "%%s\\n" "$PWD" > %q\n' "${interactive_cwd_file}" >> "${interactive_rc}"
run_client interactive "${shared_directory}" </dev/null >/dev/null 2>&1
[[ "$(<"${interactive_cwd_file}")" == "${shared_directory}" ]] ||
    fail 'interactive mode did not restore cwd'

# A failing remote command must retain its exit status through SSH and client.
failure_status=0
run_client failure "${shared_directory}" 'exit 29' \
    > "${fixture_directory}/failure.out" 2>/dev/null || failure_status=$?
[[ "${failure_status}" -eq 29 ]] ||
    fail "remote failure status changed: ${failure_status}"

printf 'PASS: generated host-shell command and interactive modes map cwd safely and preserve arguments, stdin, and exit status\n'
