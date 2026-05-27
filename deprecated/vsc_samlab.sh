#!/bin/bash
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/cluster_helpers.sh"

CLUSTER="bluehive3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--cluster)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a cluster name" >&2
                exit 1
            fi
            CLUSTER="$2"
            shift 2
            ;;
        --cluster=*)
            CLUSTER="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-a|--cluster CLUSTER]"
            echo "Supported clusters: $(cluster_supported_list)"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Unexpected argument '$1'" >&2
            exit 1
            ;;
    esac
done

require_cluster "$CLUSTER" || exit 1
"$repo_dir/start_ssh_control.sh" -a "$CLUSTER"
compute_host="$(cluster_compute_host "$CLUSTER")" || exit 1
code -n --remote "ssh-remote+$compute_host" "/home/$USER"



