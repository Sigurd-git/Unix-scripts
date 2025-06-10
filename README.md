# My Mac Scripts - Cluster Management Tools

My macOS scripts for convenient cluster management using iTerm or Terminal, with automatic hostname mapping and modern GUI interface.

## Features

- **GUI Cluster Manager**: Modern tkinter-based interface for cluster management
- **Automatic Hostname Mapping**: Supports bluehive and bhward clusters with automatic hostname resolution
- **SSH Password Automation**: Uses expect-based automation instead of sshpass dependency
- **Real-time Output**: Live command output display and monitoring
- **Persistent Credentials**: Secure credential storage with optional password saving

## Supported Clusters

- **bluehive**: `bluehive.circ.rochester.edu`
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
password  # Optional, for password saving
```

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

Host bhward
    Hostname bhward.circ.rochester.edu
    User username
    ControlMaster auto
    ControlPath /tmp/ssh_bhward

Host bluehive_compute
    Hostname bhg0061
    User username
    ProxyJump bluehive
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

### Command Line Interface

```bash
# Connect to bluehive with default parameters
./tunnel.sh

# Connect to bhward with custom parameters
./tunnel.sh -a bhward -p doppelbock -c 16 -g 1 -m 256 -t 12

# Update cursor server
./update_code.sh
```

### Parameters

- `-a CLUSTER`: Cluster name (bluehive, bhward)
- `-p PARTITION`: SLURM partition (default: doppelbock)
- `-c CPUS`: Number of CPU cores (default: 16)
- `-g GPUS`: Number of GPUs (default: 1)
- `-m MEMORY`: Memory in GB (default: 256)
- `-t TIME`: Runtime in hours (default: 12)
- `-w NODE`: Specific node (optional)
- `-n`: Disable logging

## Documentation

See the `documents/` directory for detailed documentation:
- **English**: Comprehensive guides for SSH automation, GUI usage, and method comparisons
- **中文**: 完整的中文文档，包含SSH自动化、GUI使用和方法对比

## Security Features

- Password handling through expect scripts with automatic cleanup
- No password visibility in process lists
- Cluster name validation to prevent connection errors
- Secure credential storage options
