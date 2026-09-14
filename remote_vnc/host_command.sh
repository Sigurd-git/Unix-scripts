#!/usr/bin/env bash

set -o pipefail

_host_command_name="$(basename "$0")"
_host_command_commands_file="${BH_ENV_HOST_COMMANDS_FILE:-${HOME:?HOME is required}/commands.sh}"

_host_command_fail() {
    printf '[%s] Error: %s\n' "${_host_command_name}" "$*" >&2
    exit 2
}

_host_command_load_definitions() {
    if [[ ! -e "${_host_command_commands_file}" ]]; then
        [[ -z "${BH_ENV_HOST_COMMANDS_FILE+x}" ]] ||
            _host_command_fail \
                "commands file is unavailable: ${_host_command_commands_file}"
        return 0
    fi
    [[ -f "${_host_command_commands_file}" &&
       -r "${_host_command_commands_file}" ]] ||
        _host_command_fail \
            "commands file is unreadable: ${_host_command_commands_file}"

    # The file is a definition library. Keep incidental source-time output out
    # of command discovery and proxied command streams.
    # shellcheck disable=SC1090
    source "${_host_command_commands_file}" >/dev/null 2>&1 ||
        _host_command_fail \
            "could not load commands file: ${_host_command_commands_file}"
}

_host_command_was_preexisting_function() {
    local requested_name="$1"
    local existing_name

    while IFS= read -r existing_name; do
        [[ "${existing_name}" == "${requested_name}" ]] && return 0
    done <<< "${_host_command_functions_before}"
    return 1
}

_host_command_list() {
    local command_name custom_directory executable_path

    {
        while IFS= read -r command_name; do
            [[ -n "${command_name}" && "${command_name}" != _* ]] &&
                printf '%s\n' "${command_name}"
        done < <(compgen -A alias || true)

        while IFS= read -r command_name; do
            [[ -n "${command_name}" && "${command_name}" != _* ]] ||
                continue
            _host_command_was_preexisting_function "${command_name}" ||
                printf '%s\n' "${command_name}"
        done < <(compgen -A function || true)

        for custom_directory in "${HOME}/bin" "${HOME}/.local/bin"; do
            [[ -d "${custom_directory}" ]] || continue
            for executable_path in "${custom_directory}"/*; do
                [[ -f "${executable_path}" && -x "${executable_path}" ]] ||
                    continue
                command_name="${executable_path##*/}"
                [[ "${command_name}" != _* && "${command_name}" != .* ]] &&
                    printf '%s\n' "${command_name}"
            done
        done
    } | LC_ALL=C sort -u
}

_host_command_functions_before="$(compgen -A function || true)"
unalias -a 2>/dev/null || true
shopt -s expand_aliases

case "${1:-}" in
    --list)
        [[ $# -eq 1 ]] || _host_command_fail 'usage: host_command.sh --list'
        _host_command_load_definitions
        _host_command_list
        exit 0
        ;;
esac

[[ $# -ge 2 ]] ||
    _host_command_fail \
        'usage: host_command.sh HOST_WORKING_DIRECTORY COMMAND [ARG...]'

_host_command_working_directory="$1"
_host_command_requested_command="$2"
shift 2

export PATH="${PATH:+${PATH}:}${HOME}/bin:${HOME}/.local/bin"
cd -- "${_host_command_working_directory}" ||
    _host_command_fail \
        "working directory is unavailable: ${_host_command_working_directory}"

if [[ "${_host_command_requested_command}" == /* ]]; then
    [[ -f "${_host_command_requested_command}" &&
       -x "${_host_command_requested_command}" ]] ||
        _host_command_fail \
            "executable is unavailable: ${_host_command_requested_command}"
    exec "${_host_command_requested_command}" "$@"
fi

[[ "${_host_command_requested_command}" =~ ^[A-Za-z0-9_][A-Za-z0-9._+-]*$ ]] ||
    _host_command_fail \
        "invalid command name: ${_host_command_requested_command}"

_host_command_load_definitions

if alias -- "${_host_command_requested_command}" >/dev/null 2>&1; then
    # The command name has already passed the strict name check. Parsing this
    # tiny wrapper expands its loaded alias without placing caller arguments in
    # eval text; the actual invocation still receives the original "$@" array.
    # shellcheck disable=SC2294
    eval "_host_command_invoke_alias() { ${_host_command_requested_command}"' "$@"; }'
    _host_command_invoke_alias "$@"
    exit $?
fi

if declare -F -- "${_host_command_requested_command}" >/dev/null 2>&1; then
    "${_host_command_requested_command}" "$@"
    exit $?
fi

_host_command_executable="$(type -P -- "${_host_command_requested_command}" 2>/dev/null)" ||
    _host_command_fail \
        "command is unavailable: ${_host_command_requested_command}"
exec "${_host_command_executable}" "$@"
