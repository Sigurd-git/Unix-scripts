# My Mac Scripts - Cluster Management Tools

My macOS scripts for convenient cluster management using iTerm or Terminal, with automatic hostname mapping and modern GUI interface.

## Features

- **GUI Cluster Manager**: Modern tkinter-based interface for cluster management
- **Automatic Hostname Mapping**: Supports bluehive, bluehive3, and bhward clusters with automatic hostname resolution
- **SSH Password Automation**: Uses expect-based automation instead of sshpass dependency
- **Real-time Output**: Live command output display and monitoring
- **Persistent Credentials**: Secure credential storage with optional password saving

## Supported Clusters

- **bluehive**: `bluehive.circ.rochester.edu`
- **bluehive3**: `bluehive3.circ.rochester.edu`
- **bhward**: `bhward.circ.rochester.edu`

All scripts automatically map cluster names to their full hostnames.

## Installation and Setup

### 1. Clone Repository

For zsh:
```zsh
git clone https://github.com/Sigurd-git/Unix-scripts.git
cd Unix-scripts
echo "PATH=$PWD:$PATH" >> ~/.zshrc
source ~/.zshrc
```

For bash:
```bash
git clone https://github.com/Sigurd-git/Unix-scripts.git
cd Unix-scripts
echo "PATH=$PWD:$PATH" >> ~/.bashrc
source ~/.bashrc
```

### 2. Setup Environment

```bash
# Make scripts executable
chmod 755 *

# Install Python dependencies (for GUI)
uv sync
source .venv/bin/activate
```

### 3. Configure Credentials

Create `user_password.txt` in the same directory:
```
username
password
/scratch/snormanh_lab/shared
```

The third line is the remote tool root for `code`, `cursor`, `dropbear`, and
the per-user VNC files.

### 4. SSH Configuration (Optional)

For advanced SSH features, configure `~/.ssh/config`:
```
Host *
    ControlMaster auto
    ControlPath /tmp/ssh_mux_%h_%p_%r

Host bluehive
    Hostname bluehive.circ.rochester.edu
    User username
    ControlMaster auto
    ControlPath /tmp/ssh_bluehive

Host bluehive3
    Hostname bluehive3.circ.rochester.edu
    User username
    ControlMaster auto
    ControlPath /tmp/ssh_bluehive3

Host bhward
    Hostname bhward.circ.rochester.edu
    User username
    ControlMaster auto
    ControlPath /tmp/ssh_bhward

Host bluehive_compute
    Hostname bhg0061
    User username
    ProxyJump bluehive

Host bluehive_compute3
    # remote_sshd.sh/update_ssh_config.sh rewrites this to the allocated node.
    Hostname bhg0049
    User username
    ProxyJump bluehive3
```

## Usage

### GUI Interface (Recommended)

```bash
python gui_cluster_manager.py
```

The GUI provides:
- User authentication with password save option
- Parameter configuration for all tunnel options
- Real-time output display
- Cluster selection with automatic hostname mapping
- Remote SSHD launch through `remote_sshd.sh`, including SSH config update for the allocated node
- Remote tool root configuration for automatic deployment of `code`, `cursor`, `dropbear`, and VNC files

For first-time cluster setup, see [ADMIN_INIT.md](ADMIN_INIT.md) or [ADMIN_INIT.en.md](ADMIN_INIT.en.md).

### Command Line Interface

```bash
# Start a VS Code tunnel on bluehive3 with default parameters
./tunnel.sh

# Start a VS Code tunnel on bhward with custom parameters
./tunnel.sh -a bhward -p doppelbock -c 16 -g 1 -m 256 -t 12

# Start a VS Code tunnel on bluehive3 explicitly
./tunnel.sh -a bluehive3 -p preempt -c 16 -g 1 -m 256 -t 12

# Start a Cursor tunnel instead of the default VS Code tunnel
./tunnel.sh -a bluehive3 --tool cursor -p doppelbock -c 16 -g 1 -m 256 -t 12

# Start a Dropbear SSHD job and update the compute host entry in ~/.ssh/config
./remote_sshd.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 24

# Deploy or repair remote tools manually
./deploy_remote_tools.sh -a bluehive3 --all

# Start VNC and a Slurm-bound SSH shell; add --opencodex when needed
./remote_vnc.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 24
```

### Remote VNC

`remote_vnc.sh` starts an independent Slurm job containing an Apptainer XFCE
desktop and a public-key-only SSH service. It keeps the `blhc3` SSH alias, so
both `ssh blhc3` and the terminal opened inside XFCE run in the VNC job's Slurm
cgroup.

The script reads `REMOTE_SHARED_ROOT` from the third line of
`user_password.txt`. Override it for one run with `-r` or `--root`:

```bash
./remote_vnc.sh --root /path/you/can/write --no-open
```

Small VNC scripts are copied to a checksum-named release only when that release
is absent. Passwords, keys, logs, state, and a possible private image are kept
under:

```text
$REMOTE_SHARED_ROOT/remote-vnc/users/$USER/
```

`deploy_remote_tools.sh --vnc` and `--all` copy these files but do not build a
SIF on the login node.

The preferred read-only image is:

```text
/scratch/snormanh_lab/shared/remote-vnc/images/ubuntu-vnc-xfce-g3_24.04.sif
```

If it cannot be read or fails its checksum, the VNC Slurm job builds a private
copy from the pinned Apptainer definition. Git stores the definition and
checksums, not the SIF binary. The script prints the VNC password file path but
never prints the password. Set `REMOTE_VNC_SHARED_IMAGE` before running the
script when another cluster uses a different shared SIF path.

### Automatic Illustrator Bundle Sync

`sync_ai_bundles.sh` checks the BlueHive `toydata/tmp` directory for top-level
folders containing an Illustrator file. For each new folder, it creates a
two-way-safe Mutagen session with the matching folder under `~/Downloads`.
The existing `final_paper_ai_linked` sessions remain separate.

The launch agent runs the check every five minutes:

```bash
mkdir -p "$HOME/Library/Application Support/PaperAISync"
install -m 755 sync_ai_bundles.sh \
  "$HOME/Library/Application Support/PaperAISync/sync_ai_bundles.sh"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.gliao2.paper-ai-bundles.plist"
```

Run an immediate check with:

```bash
./sync_ai_bundles.sh
```

### Parameters

- `-a CLUSTER`: Cluster name (bluehive, bluehive3, bhward; default: bluehive3)
- `-p PARTITION`: SLURM partition (default: doppelbock)
- `-c CPUS`: Number of CPU cores (default: 16)
- `-g GPUS`: Number of GPUs (default: 1)
- `-m MEMORY`: Memory in GB (default: 256)
- `-t TIME`: Runtime in hours (default: 12)
- `-w NODE`: Specific node (optional)
- `-n`: Disable logging
- `--tool code|cursor`: Tunnel backend for `tunnel.sh` (default: `code`)
- `-r, --root PATH`: Override the remote tool root from `user_password.txt`
- `--opencodex`: Start OpenCodex in `screen` and restart Codex app-server after VNC SSH is ready


## Security Features

- Password handling through expect scripts with automatic cleanup
- No password visibility in process lists
- Cluster name validation to prevent connection errors
- Secure credential storage options
