#!/bin/bash
current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
CLUSTER_DEFAULT=bluehive3
CLUSTER=$CLUSTER_DEFAULT  # Set the default value here; supported values are bluehive3, bluehive, or bhward

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

# Set HOSTNAME based on CLUSTER
if [ "$CLUSTER" = "bluehive3" ]; then
    HOSTNAME="bluehive3.circ.rochester.edu"
elif [ "$CLUSTER" = "bluehive" ]; then
    HOSTNAME="bluehive.circ.rochester.edu"
elif [ "$CLUSTER" = "bhward" ]; then
    HOSTNAME="bhward.circ.rochester.edu"
else
    echo "Error: Unknown cluster '$CLUSTER'. Supported clusters: bluehive3, bluehive, bhward"
    exit 1
fi
# Detect OS and use appropriate sshpass binary
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - Use SSH control master configuration
    $current_path/sshpass_mac_arm64 -p "$PASSWORD" ssh -o ControlMaster=auto -o StrictHostKeyChecking=no -fN $USER@$HOSTNAME
else
    # Linux
    $current_path/sshpass_linux_amd64 -p "$PASSWORD" ssh -o ControlMaster=auto -o StrictHostKeyChecking=no -fN $USER@$HOSTNAME
fi
