#!/usr/bin/env bash

set -Eeuo pipefail

matlab_executable="/gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2024b/bin/matlab"

[[ -x "${matlab_executable}" ]] || {
    printf 'MATLAB executable is missing: %s\n' "${matlab_executable}" >&2
    exit 2
}

if [[ $# -eq 0 ]]; then
    set -- -desktop
fi

exec "${matlab_executable}" "$@"
