#!/bin/bash
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/cluster_helpers.sh"

CLUSTER="${SCANCEL_CLUSTER:-bluehive3}"
SCANCEL_ARGS=()
SSH_LOCALE_ENV=(LC_ALL=C LANG=C LC_CTYPE=C)

usage() {
    cat <<EOF
Usage: $(basename "$0") [wrapper-options] [--] [scancel-options] [job_id ...]

Wrapper options:
  -a, --cluster CLUSTER          SSH cluster to run scancel on
      --remote-cluster CLUSTER   Same as --cluster, avoids scancel option clashes
      --wrapper-help             Show this help

All other arguments are forwarded unchanged to remote scancel.
Use -- when a scancel argument conflicts with a wrapper option.
EOF
}

set_cluster() {
    if ! require_cluster "$1"; then
        exit 1
    fi
    CLUSTER="$1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wrapper-help)
                usage
                exit 0
                ;;
            -a|--cluster|--remote-cluster)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    echo "Error: $1 requires a cluster name" >&2
                    exit 1
                fi
                set_cluster "$2"
                shift 2
                ;;
            --cluster=*|--remote-cluster=*)
                set_cluster "${1#*=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    SCANCEL_ARGS=("$@")
}

shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

build_remote_command() {
    local remote_command=""
    local arg

    for arg in scancel "$@"; do
        if [[ -n "$remote_command" ]]; then
            remote_command+=" "
        fi
        remote_command+="$(shell_quote "$arg")"
    done

    printf "%s" "$remote_command"
}

main() {
    local remote_command
    local login_command

    parse_args "$@"

    env "${SSH_LOCALE_ENV[@]}" "$script_dir/start_ssh_control.sh" -a "$CLUSTER" || exit $?

    remote_command="$(build_remote_command "${SCANCEL_ARGS[@]}")"
    login_command="LC_ALL=C LANG=C LC_CTYPE=C bash -lc $(shell_quote "$remote_command")"
    exec env "${SSH_LOCALE_ENV[@]}" ssh -T "$CLUSTER" "$login_command"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
