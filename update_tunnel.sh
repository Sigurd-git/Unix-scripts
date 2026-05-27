#!/bin/bash
current_path="$(dirname "$0")"
source "$current_path/cluster_helpers.sh"

CLUSTER="bluehive3"

usage() {
    echo "Usage: $0 [-a|--cluster CLUSTER]"
    echo "Supported clusters: $(cluster_supported_list)"
}

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
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Unexpected argument '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cluster "$CLUSTER" || exit 1
HOSTNAME="$(cluster_hostname "$CLUSTER")" || exit 1

source "$current_path/start_ssh_control.sh" -a "$CLUSTER"

# Define variables
INSTALL_DIR="/home/$USER/.cursor/cli/servers"
# Get commit info locally
commit=$(cursor --version | head -n 2 | tail -n 1 | cut -d ' ' -f 2)
version=$(cursor --version | head -n 1 | cut -d ' ' -f 2)
DOWNLOAD_URL="https://cursor.blob.core.windows.net/remote-releases/${version}-${commit}/vscode-reh-linux-x64.tar.gz"

echo "Updating Cursor Server to version $version..."

# Execute commands on remote server
ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no "$USER@$HOSTNAME"<<ENDSSH
cd "$INSTALL_DIR"
module load pigz
# Check if the version already exists
if [ -d "cursor-${commit}" ]; then
    echo "Cursor Server version ${commit} already exists in $INSTALL_DIR/cursor-${commit}!"
else
    # Download and install the new version
    echo "Downloading Cursor Server from $DOWNLOAD_URL..."
    wget --progress=bar:force "$DOWNLOAD_URL" -O "vscode-reh-linux-x64.tar.gz"
    mkdir -p Stable-${commit}
    # Determine whether pigz is available on the compute node; use it for faster decompression if present
    if command -v pigz >/dev/null 2>&1; then
        echo "pigz detected: using parallel decompression."
        srun -p doppelbock -c 16 -t 00:10:00 bash -c 'pigz -dc "$INSTALL_DIR/vscode-reh-linux-x64.tar.gz" | tar -x -C Stable-${commit} --strip-components=1 -f -'
    else
        echo "pigz not found: falling back to single-threaded tar -xzf."
        srun -p doppelbock -c 8 -t 00:10:00 tar -xzf "vscode-reh-linux-x64.tar.gz" -C Stable-${commit} --strip-components=1
    fi
    rm "vscode-reh-linux-x64.tar.gz"
    echo "Cursor Server updated successfully in $INSTALL_DIR/Stable-${commit}!"
fi

ENDSSH
