#!/bin/bash
current_path="$(dirname "$0")"

CLUSTER_DEFAULT=bluehive
CLUSTER=$CLUSTER_DEFAULT  # Set the default value here, it can be bluehive or bhward

# 使用getopt处理命令行选项
TEMP=$(getopt -o a: --long cluster: -n 'ssh_control.sh' -- "$@")
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi

# Process the arguments passed to the script
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
            echo "Internal error!"
            exit 1
            ;;
    esac
done

echo "Starting SSH session to $CLUSTER."
ssh -o StrictHostKeyChecking=no -fN $CLUSTER
