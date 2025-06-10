#!/bin/bash
current_path="$(dirname "$0")"
source $current_path/start_ssh_control.sh 

CLUSTER="bluehive"
HOSTNAME="bluehive.circ.rochester.edu"
# Define variables
INSTALL_DIR="/home/$USER/.cursor/cli/servers"
# Get commit info locally
commit=$(cursor --version | head -n 2 | tail -n 1 | cut -d ' ' -f 2)
version=$(cursor --version | head -n 1 | cut -d ' ' -f 2)
DOWNLOAD_URL="https://cursor.blob.core.windows.net/remote-releases/${version}-${commit}/vscode-reh-linux-x64.tar.gz"

echo "Updating Cursor Server to version $version..."

# Execute commands on remote server
ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no $USER@$HOSTNAME<<ENDSSH
cd "$INSTALL_DIR"
# Check if the version already exists
if [ -d "cursor-${commit}" ]; then
    echo "Cursor Server version ${commit} already exists in $INSTALL_DIR/cursor-${commit}!"
else
    # Download and install the new version
    echo "Downloading Cursor Server from $DOWNLOAD_URL..."
    wget --progress=bar:force "$DOWNLOAD_URL" -O "vscode-reh-linux-x64.tar.gz"
    mkdir -p Stable-${commit}
    srun -p doppelbock -c 4 -t 00:10:00 tar -xzf "vscode-reh-linux-x64.tar.gz" -C Stable-${commit} --strip-components=1
    rm "vscode-reh-linux-x64.tar.gz"
    echo "Cursor Server updated successfully in $INSTALL_DIR/cursor-${commit}!"
fi

ENDSSH