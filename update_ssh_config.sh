#!/bin/zsh

# Default values
CLUSTER="bluehive"
NODE=""
PARTITION="doppelbock"
PORT="22"  # 默认SSH端口

# Parse command line arguments
while getopts "a:w:p:o:" opt; do
    case $opt in
        a) CLUSTER="$OPTARG" ;;
        w) NODE="$OPTARG" ;;
        p) PARTITION="$OPTARG" ;;
        o) PORT="$OPTARG" ;;
        ?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
done

# SSH config file path
SSH_CONFIG="$HOME/.ssh/config"

# If node is specified, use it directly
if [ -n "$NODE" ]; then
    sed -i '' '/^Host '$CLUSTER'_compute/,/Hostname/{s/Hostname.*/Hostname '$NODE'/;}' "$SSH_CONFIG"
    # Update port
    sed -i '' '/^Host '$CLUSTER'_compute/,/Port/{s/Port.*/Port '$PORT'/;}' "$SSH_CONFIG"
# Otherwise use default logic based on partition
else
    if [ "$PARTITION" = "doppelbock" ]; then
        sed -i '' '/^Host '$CLUSTER'_compute/,/Hostname/{s/Hostname.*/Hostname bhg0061/;}' "$SSH_CONFIG"
    elif [ "$PARTITION" = "dmi" ]; then
        sed -i '' '/^Host '$CLUSTER'_compute/,/Hostname/{s/Hostname.*/Hostname bhc0208/;}' "$SSH_CONFIG"
    else
        echo "Error: Unknown partition $PARTITION" >&2
        exit 1
    fi
    # Update port
    sed -i '' '/^Host '$CLUSTER'_compute/,/Port/{s/Port.*/Port '$PORT'/;}' "$SSH_CONFIG"
fi

echo "Updated SSH config for $CLUSTER with node: $(grep -A1 "^Host ${CLUSTER}_compute" "$SSH_CONFIG" | grep Hostname | awk '{print $2}') and port: $PORT" 