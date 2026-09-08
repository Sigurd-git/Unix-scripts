#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_directory}/cluster_helpers.sh"

cluster_name="bluehive3"

print_usage() {
    cat <<'EOF'
Usage: cluster_ssh.sh [-a|--cluster CLUSTER] [--] [remote-command [argument ...]]

Open the cluster login node without requiring a ~/.ssh/config entry.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--cluster)
            [[ -n "${2:-}" && "$2" != -* ]] || {
                echo "Error: $1 requires a cluster name" >&2
                exit 1
            }
            cluster_name="$2"
            shift 2
            ;;
        --cluster=*)
            cluster_name="${1#*=}"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

require_cluster "${cluster_name}" || exit 1
# shellcheck disable=SC1090
source "${script_directory}/start_ssh_control.sh" --cluster "${cluster_name}"

ssh_arguments=(
    -F /dev/null
    -o "ControlPath=${SSH_CONTROL_PATH}"
)
[[ $# -gt 0 ]] && ssh_arguments+=(-T)

exec /usr/bin/ssh "${ssh_arguments[@]}" "${SSH_LOGIN_TARGET}" "$@"
