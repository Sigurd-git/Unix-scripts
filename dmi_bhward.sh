#!/bin/bash
current_path="$(dirname "$0")"
source "$current_path/cluster_helpers.sh"

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
            echo "Usage: $0 [-a|--cluster CLUSTER] [cpus hours memory_mb]"
            echo "Supported clusters: $(cluster_supported_list)"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: Unexpected option '$1'" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

require_cluster "$CLUSTER" || exit 1
source "$current_path/start_ssh_control.sh" -a "$CLUSTER"

#set default values to be 32 cpu cores 12 hours and 32GB of memory
if [ -z "$1" ]
then
    set -- 32 12 32000
fi
ssh "$CLUSTER" "screen -dmS dmi salloc -N 1 -n $1 -p dmi -t $2:00:00 --mem $3"
