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

The third line is the remote tool root for `code`, `cursor`, and `dropbear`.

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
- Remote tool root configuration for automatic deployment of `code`, `cursor`, and `dropbear`

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
- `--root PATH`: Override the remote tool root from `user_password.txt`


## Security Features

- Password handling through expect scripts with automatic cleanup
- No password visibility in process lists
- Cluster name validation to prevent connection errors
- Secure credential storage options
