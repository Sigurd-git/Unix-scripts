#!/bin/bash
current_path="$(dirname "$0")"
source $current_path/start_ssh_control.sh 

# Define variables
INSTALL_DIR="/home/$USER/.cursor-server"
# Get commit info locally
commit=$(cursor --version | head -n 2 | tail -n 1 | cut -d ' ' -f 2)
DOWNLOAD_URL="https://cursor.blob.core.windows.net/remote-releases/${commit}/cli-alpine-x64.tar.gz"

# Set HOSTNAME based on CLUSTER
if [ "$CLUSTER" = "bluehive" ]; then
    HOSTNAME="bluehive.circ.rochester.edu"
elif [ "$CLUSTER" = "bhward" ]; then
    HOSTNAME="bhward.circ.rochester.edu"
else
    echo "Error: Unknown cluster '$CLUSTER'. Supported clusters: bluehive, bhward"
    exit 1
fi

echo "Updating Cursor Server to version $version..."

# Execute commands on remote server
ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no $USER@$HOSTNAME<<ENDSSH
cd "$INSTALL_DIR"
# Check if the version already exists
if [ -d "cursor-${commit}" ]; then
    echo "Cursor Server version ${commit} already exists in $INSTALL_DIR/cursor-${commit}!"
else
    # Download and install the new version
    curl -L -o "cli-alpine-x64.tar.gz" "$DOWNLOAD_URL"
    tar -xzf "cli-alpine-x64.tar.gz"
    mv cursor cursor-${commit}
    rm "cli-alpine-x64.tar.gz"
    echo "Cursor Server updated successfully in $INSTALL_DIR/cursor-${commit}!"
fi

ENDSSH