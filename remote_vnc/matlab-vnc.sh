#!/usr/bin/env bash

set -Eeuo pipefail

environment_name="${1:-${BH_ENV_NAME:-default}}"
[[ $# -eq 0 ]] || shift

if [[ "${environment_name}" == "--host" ]]; then
    matlab_executable="/gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2024b/bin/matlab"
    [[ -x "${matlab_executable}" ]] || {
        printf 'Host MATLAB executable is missing: %s\n' \
            "${matlab_executable}" >&2
        exit 2
    }

    if [[ $# -eq 0 ]]; then
        set -- -desktop
    fi
    exec "${matlab_executable}" "$@"
fi

[[ "${environment_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Invalid environment name: %s\n' "${environment_name}" >&2
    exit 2
}
bh_env_executable="${HOME}/.local/bin/bh-env"
[[ -x "${bh_env_executable}" ]] || {
    printf 'bh-env is unavailable: %s\n' "${bh_env_executable}" >&2
    exit 2
}

if [[ $# -eq 0 ]]; then
    set -- -desktop
fi

exec "${bh_env_executable}" --env "${environment_name}" \
    exec -- matlab "$@"
