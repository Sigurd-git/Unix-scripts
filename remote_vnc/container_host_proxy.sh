#!/usr/bin/env bash

set -Eeuo pipefail

proxy_name="$(basename "$0")"
: "${BH_ENV_NAME:?BH_ENV_NAME is required}"
: "${BH_ENV_HOST_HOME:?BH_ENV_HOST_HOME is required}"
: "${BH_ENV_HOST_PERSISTENT_HOME:?BH_ENV_HOST_PERSISTENT_HOME is required}"
: "${BH_ENV_CONTAINER_HOME:?BH_ENV_CONTAINER_HOME is required}"
: "${BH_ENV_HOST_SHELL:?BH_ENV_HOST_SHELL is required}"
: "${BH_ENV_HOST_COMMAND:?BH_ENV_HOST_COMMAND is required}"

fail() {
    printf '[%s] Error: %s\n' "${proxy_name}" "$*" >&2
    exit 1
}

run_host_bh_env() {
    local remote_command
    local -a remote_arguments=("${BH_ENV_HOST_COMMAND}" "$@")

    printf -v remote_command '%q ' "${remote_arguments[@]}"
    exec "${BH_ENV_HOST_SHELL}" "${remote_command% }"
}

map_container_path_to_host() {
    local container_path="$1"

    case "${container_path}" in
        "${BH_ENV_CONTAINER_HOME}")
            printf '%s\n' "${BH_ENV_HOST_PERSISTENT_HOME}"
            ;;
        "${BH_ENV_CONTAINER_HOME}/"*)
            printf '%s%s\n' \
                "${BH_ENV_HOST_PERSISTENT_HOME}" \
                "${container_path#"${BH_ENV_CONTAINER_HOME}"}"
            ;;
        /bluehive-home)
            printf '%s\n' "${BH_ENV_HOST_HOME}"
            ;;
        /bluehive-home/*)
            printf '%s%s\n' \
                "${BH_ENV_HOST_HOME}" "${container_path#/bluehive-home}"
            ;;
        /host)
            printf '/\n'
            ;;
        /host/*)
            printf '/%s\n' "${container_path#/host/}"
            ;;
        /gpfs/fs1|/gpfs/fs1/*|/gpfs/fs2|/gpfs/fs2/*|/scratch|/scratch/*)
            printf '%s\n' "${container_path}"
            ;;
        *)
            return 1
            ;;
    esac
}

host_command_runner="${BH_ENV_HOST_PERSISTENT_HOME}/.local/state/remote-vnc/ssh/${SLURM_JOB_ID:?SLURM_JOB_ID is required}/host-command.sh"

run_host_command() {
    local host_working_directory remote_command argument mapped_argument
    local -a remote_arguments

    if ! host_working_directory="$(map_container_path_to_host "${PWD}")"; then
        case "$1" in
            slab|sq|squeue|sinfo|sacct|sprio|sstat|sshare|sdiag|sreport)
                host_working_directory="${BH_ENV_HOST_HOME}"
                ;;
            *) fail "the current directory is container-only; use a directory under home, /bluehive-home, /gpfs, or /scratch" ;;
        esac
    fi
    remote_arguments=("${host_command_runner}" "${host_working_directory}")
    for argument in "$@"; do
        if [[ "${argument}" == --*=/* ]]; then
            mapped_argument="$(map_container_path_to_host "${argument#*=}" || true)"
            [[ -z "${mapped_argument}" ]] || argument="${argument%%=*}=${mapped_argument}"
        elif [[ "${argument}" == /* ]]; then
            mapped_argument="$(map_container_path_to_host "${argument}" || true)"
            [[ -z "${mapped_argument}" ]] || argument="${mapped_argument}"
        fi
        remote_arguments+=("${argument}")
    done
    printf -v remote_command '%q ' "${remote_arguments[@]}"
    exec "${BH_ENV_HOST_SHELL}" "${remote_command% }"
}

refresh_host_commands() {
    local remote_command command_names command_name command_link
    local custom_bin="${BH_ENV_CONTAINER_HOME}/.local/state/remote-vnc/ssh/${SLURM_JOB_ID}/custom-bin"

    printf -v remote_command '%q --list' "${host_command_runner}"
    command_names="$("${BH_ENV_HOST_SHELL}" "${remote_command}")" ||
        fail "could not discover the host's custom commands"
    mkdir -p "${custom_bin}"
    # Remove only links owned by this bridge, preserving user-installed files.
    for command_link in "${custom_bin}/"*; do
        [[ -L "${command_link}" ]] || continue
        [[ "$(readlink "${command_link}")" == ../bin/container-host-proxy ]] || continue
        rm -f -- "${command_link}"
    done
    while IFS= read -r command_name; do
        [[ "${command_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
        case "${command_name}" in
            act|swap_bluehive|revert_bluehive|bh-env|bh-admin|bh-host|sbatch|ocx|codex) continue ;;
        esac
        command_link="${custom_bin}/${command_name}"
        [[ -e "${command_link}" || -L "${command_link}" ]] ||
            ln -s ../bin/container-host-proxy "${command_link}"
    done <<< "${command_names}"
    printf 'Host custom commands refreshed from ~/commands.sh and personal bin directories.\n'
}

case "${proxy_name}" in
    bh-host)
        case "${1:-}" in
            --refresh) refresh_host_commands ;;
            -h|--help|"")
                printf 'Usage: bh-host COMMAND [ARG ...]\n       bh-host --refresh\n'
                ;;
            *) run_host_command "$@" ;;
        esac
        ;;
    bh-env)
        run_host_bh_env "$@"
        ;;
    bh-admin)
        [[ "${1:-}" == "--" ]] && shift
        if [[ $# -gt 0 ]]; then
            run_host_bh_env --env "${BH_ENV_NAME}" admin -- "$@"
        else
            run_host_bh_env --env "${BH_ENV_NAME}" admin
        fi
        ;;
    sbatch)
        [[ "${1:-}" == "--" ]] && shift
        source_script="${1:-}"
        [[ -n "${source_script}" ]] || fail "a Bash script is required"
        shift
        source_script_path="$(readlink -f -- "${source_script}")" ||
            fail "script is unavailable: ${source_script}"
        [[ -r "${source_script_path}" ]] ||
            fail "script is unreadable: ${source_script_path}"
        host_script_path="$(
            map_container_path_to_host "${source_script_path}"
        )" || fail \
            "script must be under the container home, /bluehive-home, /gpfs, /scratch, or /host"
        run_host_bh_env \
            --env "${BH_ENV_NAME}" sbatch "${host_script_path}" "$@"
        ;;
    *)
        run_host_command "${proxy_name}" "$@"
        ;;
esac
