#!/bin/bash
args=()
# Parse arguments
while [[ $# -gt 0 ]]; do
    args+=("$1")
    shift
done

# Execute cisc.sh
current_dir=$(dirname "$0")
source "$current_dir/cisc.sh"

# Execute start_ssh_control.sh with filtered arguments
"$current_dir/start_ssh_control.sh" "${args[@]}"
