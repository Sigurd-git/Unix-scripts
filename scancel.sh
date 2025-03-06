#!/bin/bash
current_path="$(dirname "$0")"

CLUSTER=bluehive

# Use getopt to parse command line options
TEMP=$(getopt -o a: --long cluster: -n 'scancel.sh' -- "$@")
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi

# Reorder command line arguments
eval set -- "$TEMP"

while true; do
    case "$1" in
        -a|--cluster)
            CLUSTER=$2
            shift 2
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

# Check if job ID argument is provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 [options] job_id [extra parameters]"
    exit 1
fi
JOB_ID=$1
shift
EXTRA_ARGS="$@"

# Source SSH control script
source "$current_path/start_ssh_control.sh" -a $CLUSTER

# SSH into the cluster and cancel the specified job
ssh $CLUSTER <<ENDSSH
    echo "---------------------------------"
    echo "Canceling job with ID: ${JOB_ID} with extra parameters: ${EXTRA_ARGS}"
    scancel ${JOB_ID} ${EXTRA_ARGS}
    echo "Job ${JOB_ID} has been cancelled."
    echo "---------------------------------"
ENDSSH