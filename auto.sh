#!/bin/bash

# Initialize variables
workspace_path="/scratch/snormanh_lab/shared/Sigurd/encodingmodel"
args=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --path)
            workspace_path="$2"
            shift 2
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

# Execute cisc.sh
current_dir=$(dirname "$0")
source "$current_dir/cisc.sh"

# Execute remote_sshd.sh with filtered arguments
"$current_dir/remote_sshd.sh" "${args[@]}"

# Open VSCode with the specified workspace
code -n --remote ssh-remote+bluehive_compute "$workspace_path" 