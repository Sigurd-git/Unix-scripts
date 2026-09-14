#!/usr/bin/env bash

# Run locally: bash tests/test_remote_vnc_host_command.sh
# User commands and Slurm executables are represented by local fixtures.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_command="${repository_directory}/remote_vnc/host_command.sh"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT

fixture_home="${fixture_directory}/home"
fixture_bin="${fixture_directory}/slurm bin"
working_directory="${fixture_directory}/working directory"
absolute_script_directory="${fixture_directory}/absolute scripts"
commands_file="${fixture_directory}/custom commands.sh"
mkdir -p "${fixture_home}/bin" "${fixture_home}/.local/bin" \
    "${fixture_bin}" "${working_directory}" "${absolute_script_directory}"

cat > "${commands_file}" <<'COMMANDS'
printf 'commands stdout noise\n'
printf 'commands stderr noise\n' >&2

alias act='printf "act:%s\n"'
alias cp='printf "cp:%s|%s\n"'
alias squeue='squeue -O broad'
alias sq='squeue -O concise'
alias _private_alias='printf "private alias\n"'

slab() {
    printf 'slab-cwd:%s\n' "$PWD"
    printf 'slab-arg:%s\n' "$@"
}

readpipe() {
    local input_line
    IFS= read -r input_line
    printf 'stdin:%s\n' "${input_line}"
}

fail_function() {
    printf 'function failure\n' >&2
    return 29
}

_helper_function() {
    return 0
}
COMMANDS

cat > "${fixture_bin}/squeue" <<'MOCK_SQUEUE'
#!/usr/bin/env bash
printf 'squeue-cwd:%s\n' "$PWD"
printf 'squeue-arg:%s\n' "$@"
MOCK_SQUEUE

cat > "${fixture_home}/bin/custom-tool" <<'CUSTOM_TOOL'
#!/usr/bin/env bash
printf 'custom:%s\n' "$1"
CUSTOM_TOOL

cat > "${fixture_home}/.local/bin/fail-tool" <<'FAIL_TOOL'
#!/usr/bin/env bash
printf 'external failure\n' >&2
exit 37
FAIL_TOOL

cat > "${fixture_home}/bin/_private-tool" <<'PRIVATE_TOOL'
#!/usr/bin/env bash
exit 0
PRIVATE_TOOL

absolute_script="${absolute_script_directory}/absolute command"
cat > "${absolute_script}" <<'ABSOLUTE_SCRIPT'
#!/usr/bin/env bash
printf 'absolute-cwd:%s\n' "$PWD"
printf 'absolute-arg:%s\n' "$@"
ABSOLUTE_SCRIPT

printf '#!/usr/bin/env bash\nexit 0\n' > "${fixture_home}/bin/duplicate"
printf '#!/usr/bin/env bash\nexit 0\n' > "${fixture_home}/.local/bin/duplicate"
printf '#!/usr/bin/env bash\nexit 0\n' > "${fixture_home}/bin/not-executable"
mkdir -p "${fixture_home}/bin/executable-directory"
chmod +x "${fixture_bin}/squeue" "${fixture_home}/bin/custom-tool" \
    "${fixture_home}/.local/bin/fail-tool" \
    "${fixture_home}/bin/_private-tool" "${fixture_home}/bin/duplicate" \
    "${fixture_home}/.local/bin/duplicate" \
    "${fixture_home}/bin/executable-directory" "${absolute_script}"

run_host_command() {
    HOME="${fixture_home}" \
    PATH="${fixture_bin}:/usr/bin:/bin" \
    BH_ENV_HOST_COMMANDS_FILE="${commands_file}" \
        bash "${host_command}" "$@"
}

expected_list=$'act\ncp\ncustom-tool\nduplicate\nfail-tool\nfail_function\nreadpipe\nslab\nsq\nsqueue'
actual_list="$(run_host_command --list 2> "${fixture_directory}/list-stderr")"
[[ "${actual_list}" == "${expected_list}" ]]
[[ ! -s "${fixture_directory}/list-stderr" ]]
cp "${commands_file}" "${fixture_home}/commands.sh"
default_list="$(
    env -u BH_ENV_HOST_COMMANDS_FILE \
        HOME="${fixture_home}" PATH="${fixture_bin}:/usr/bin:/bin" \
        bash "${host_command}" --list \
        2> "${fixture_directory}/default-list-stderr"
)"
[[ "${default_list}" == "${expected_list}" ]]
[[ ! -s "${fixture_directory}/default-list-stderr" ]]
printf 'PASS: --list uses HOME/commands.sh by default and the override quietly\n'
printf 'PASS: --list is sorted, unique, and excludes private or non-executable entries\n'

literal_argument='literal $(touch should-not-exist) ; * [abc]'
slab_output="$(run_host_command "${working_directory}" slab \
    'first argument' '' "${literal_argument}")"
expected_slab_output="$(printf 'slab-cwd:%s\nslab-arg:%s\nslab-arg:%s\nslab-arg:%s' \
    "${working_directory}" 'first argument' '' "${literal_argument}")"
[[ "${slab_output}" == "${expected_slab_output}" ]]
[[ ! -e "${working_directory}/should-not-exist" ]]
printf 'PASS: functions preserve cwd, empty arguments, spaces, and literal shell syntax\n'

alias_output="$(run_host_command "${working_directory}" cp \
    'source with spaces' 'literal $(touch alias-injection)')"
[[ "${alias_output}" == \
   'cp:source with spaces|literal $(touch alias-injection)' ]]
[[ ! -e "${working_directory}/alias-injection" ]]
printf 'PASS: aliases expand while caller arguments remain quoted data\n'

direct_squeue_output="$(run_host_command "${working_directory}" squeue 'job name')"
expected_direct_squeue_output="$(printf 'squeue-cwd:%s\nsqueue-arg:%s\nsqueue-arg:%s\nsqueue-arg:%s' \
    "${working_directory}" '-O' 'broad' 'job name')"
[[ "${direct_squeue_output}" == "${expected_direct_squeue_output}" ]]

nested_alias_output="$(run_host_command "${working_directory}" sq 'job name')"
expected_nested_alias_output="$(printf 'squeue-cwd:%s\nsqueue-arg:%s\nsqueue-arg:%s\nsqueue-arg:%s\nsqueue-arg:%s\nsqueue-arg:%s' \
    "${working_directory}" '-O' 'broad' '-O' 'concise' 'job name')"
[[ "${nested_alias_output}" == "${expected_nested_alias_output}" ]]

cat > "${fixture_directory}/normal-aliases.sh" <<'NORMAL_ALIASES'
#!/usr/bin/env bash
shopt -s expand_aliases
source "$1" >/dev/null 2>&1
shift
squeue "$@"
sq "$@"
NORMAL_ALIASES
normal_alias_output="$(
    cd "${working_directory}"
    PATH="${fixture_bin}:/usr/bin:/bin" \
        bash "${fixture_directory}/normal-aliases.sh" \
        "${commands_file}" 'job name'
)"
[[ "${normal_alias_output}" == \
   "${direct_squeue_output}"$'\n'"${nested_alias_output}" ]]
printf 'PASS: self and nested aliases match normal Bash expansion without duplication\n'

stdin_output="$(printf '%s\n' 'input with spaces and $(literal)' |
    run_host_command "${working_directory}" readpipe)"
[[ "${stdin_output}" == 'stdin:input with spaces and $(literal)' ]]
printf 'PASS: proxied functions preserve stdin\n'

custom_output="$(run_host_command "${working_directory}" custom-tool \
    'custom argument with spaces')"
[[ "${custom_output}" == 'custom:custom argument with spaces' ]]
printf 'PASS: executable commands under HOME/bin are available without changing PATH upstream\n'

absolute_output="$(run_host_command "${working_directory}" "${absolute_script}" \
    'absolute argument' 'literal $(touch absolute-injection)')"
expected_absolute_output="$(printf 'absolute-cwd:%s\nabsolute-arg:%s\nabsolute-arg:%s' \
    "${working_directory}" 'absolute argument' \
    'literal $(touch absolute-injection)')"
[[ "${absolute_output}" == "${expected_absolute_output}" ]]
[[ ! -e "${working_directory}/absolute-injection" ]]
printf 'PASS: absolute executable paths preserve cwd and literal arguments\n'

function_status=0
run_host_command "${working_directory}" fail_function \
    > "${fixture_directory}/function-stdout" \
    2> "${fixture_directory}/function-stderr" || function_status=$?
[[ "${function_status}" -eq 29 ]]
[[ ! -s "${fixture_directory}/function-stdout" ]]
grep -Fxq 'function failure' "${fixture_directory}/function-stderr"

external_status=0
run_host_command "${working_directory}" fail-tool \
    > "${fixture_directory}/external-stdout" \
    2> "${fixture_directory}/external-stderr" || external_status=$?
[[ "${external_status}" -eq 37 ]]
[[ ! -s "${fixture_directory}/external-stdout" ]]
grep -Fxq 'external failure' "${fixture_directory}/external-stderr"
printf 'PASS: function and executable failures preserve stderr and exit status\n'
