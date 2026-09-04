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

case "${proxy_name}" in
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
        fail "unsupported proxy name"
        ;;
esac
