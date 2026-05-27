#!/bin/bash

# Initialize variables
current_dir=$(dirname "$0")
source "$current_dir/cluster_helpers.sh"

workspace_path="/scratch/snormanh_lab/shared/Sigurd/encodingmodel"
cluster="bluehive3"
args=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --path)
            workspace_path="$2"
            shift 2
            ;;
        -a|--cluster)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a cluster name" >&2
                exit 1
            fi
            cluster="$2"
            require_cluster "$cluster" || exit 1
            args+=("-a" "$cluster")
            shift 2
            ;;
        --cluster=*)
            cluster="${1#*=}"
            require_cluster "$cluster" || exit 1
            args+=("-a" "$cluster")
            shift
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

require_cluster "$cluster" || exit 1
compute_host="$(cluster_compute_host "$cluster")" || exit 1

# Execute cisc.sh
source "$current_dir/cisc.sh"

# Execute remote_sshd.sh with filtered arguments
"$current_dir/remote_sshd.sh" "${args[@]}"

# Open VSCode with the specified workspace
code -n --remote "ssh-remote+$compute_host" "$workspace_path"
