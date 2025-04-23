#!/bin/bash
current_path="$(dirname "$0")"
source $current_path/start_ssh_control.sh 

# Define variables
INSTALL_DIR="/home/$USER/.cursor/cli/servers/"
# Get commit info locally
commit=$(cursor --version | head -n 2 | tail -n 1 | cut -d ' ' -f 2)
version=$(cursor --version | head -n 1 | cut -d ' ' -f 2)
DOWNLOAD_URL="https://cursor.blob.core.windows.net/remote-releases/${version}-${commit}/vscode-reh-linux-x64.tar.gz"


echo "Updating Cursor Server to version $version..."

# Execute commands on remote server
ssh bluehive<<ENDSSH
cd "$INSTALL_DIR"
# Check if the version already exists
if [ -d "cursor-${commit}" ]; then
    echo "Cursor Server version ${commit} already exists in $INSTALL_DIR/cursor-${commit}!"
else
    # Download and install the new version
    curl -L "$DOWNLOAD_URL" -o "vscode-reh-linux-x64.tar.gz"
    mkdir -p Stable-${commit}
    srun -p interactive -c 8 -t 00:10:00 tar -xzf "vscode-reh-linux-x64.tar.gz" -C Stable-${commit} --strip-components=1
    rm "vscode-reh-linux-x64.tar.gz"
    echo "Cursor Server updated successfully in $INSTALL_DIR/cursor-${commit}!"
fi

ENDSSH