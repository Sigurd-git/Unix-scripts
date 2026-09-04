# My Mac Scripts - Cluster Management Tools

My macOS scripts for convenient cluster management using iTerm or Terminal, with automatic hostname mapping and modern GUI interface.

## Features

- **GUI Cluster Manager**: Modern tkinter-based interface for cluster management
- **Automatic Hostname Mapping**: Supports bluehive, bluehive3, and bhward clusters with automatic hostname resolution
- **Reusable Login Connection**: Reuses an OpenSSH control master, so a running connection does not request the login password again
- **Slurm-aware Remote Access**: Starts VS Code/Cursor tunnels, Dropbear SSHD, or VNC inside separate Slurm jobs
- **VNC Compute Shell**: `ssh blhc3` and the XFCE Host Terminal use the VNC job's CPU, memory, GPU, and cgroup
- **Persistent Apptainer Environment**: Gives each user a writable fakeroot sandbox with `apt`, MATLAB, CUDA, Chrome, ChatGPT, uv, pixi, and compilers
- **Container Batch Jobs**: `bh-env sbatch job.sh` preserves the script's `#SBATCH` directives and runs the complete Bash script in the environment
- **Self-deploying Remote Files**: Copies missing tools and checksum-versioned VNC files under `REMOTE_SHARED_ROOT`
- **Real-time Output**: Shows job state, allocated node, startup stage, and failure logs

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
chmod 755 ./*.sh

# Install Python dependencies (for GUI)
uv sync
```

### 3. Configure Credentials

Create `user_password.txt` in the same directory:
```
username
password
/scratch/username
```

The third line is the remote tool root for `code`, `cursor`, `dropbear`, and
the per-user VNC files. Prefer a directory owned by the account instead of
another user's directory. Protect this local file and never commit it:

```bash
chmod 600 user_password.txt
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

Host bluehive_compute3 blhc3
    # remote_sshd.sh and remote_vnc.sh rewrite these values for the allocation.
    Hostname bhg0049
    Port 22
    User username
    ProxyJump bluehive3
    ControlMaster auto
    ControlPath /tmp/ssh_bluehive_compute3
```

## Usage

### GUI Interface (Recommended)

```bash
uv run python gui_cluster_manager.py
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

# Copy only the VNC release files; this does not build a SIF on the login node
./deploy_remote_tools.sh -a bluehive3 --vnc

# Start VNC, OpenCodex, Codex app-server, and a Slurm-bound SSH shell
./remote_vnc.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 24

# Use a named persistent environment
./remote_vnc.sh --env analysis --restart

# Keep the original read-only VNC image
./remote_vnc.sh --immutable --restart

# Reuse the running VNC job without opening Screen Sharing
./remote_vnc.sh --no-open
```

### Remote VNC and Slurm-bound SSH

`remote_vnc.sh` starts an independent Slurm job containing an Apptainer XFCE
desktop. The default `default` environment is a persistent writable sandbox.
The job remains separate from the `my_sshd` job created by `remote_sshd.sh`.

The VNC job starts two host-side SSH services:

- The Mac connects to a public-key-only service using `ssh blhc3`.
- The **Bluehive Host Terminal** inside XFCE connects back to the compute host.

Both shells inherit the VNC job's Slurm environment and batch cgroup. They can
use host programs, environment modules, `/gpfs/fs1`, `/gpfs/fs2`, and
`/scratch` without escaping the allocated CPU, memory, or GPU limits.

The sandbox maps the current user to root only inside the container when
`bh-env admin` is running. It cannot change the host, read files the account
cannot normally read, request unallocated GPUs, or bypass Slurm limits.

For a mutable environment, the job also starts OpenCodex and Codex app-server
inside one job-scoped Apptainer service instance. `ocx` and `codex` entered
through `ssh blhc3` join that same instance, so the client, proxy, and daemon
share one PID namespace. Ordinary SSH commands continue to run on the compute
host.

#### Start or reuse VNC

Start with the defaults (16 CPUs, 1 GPU, 256 GiB, 24 hours):

```bash
./remote_vnc.sh
```

The script opens macOS Screen Sharing after the SSH and VNC checks pass. Keep
the job and tunnel running without opening the viewer with:

```bash
./remote_vnc.sh --no-open
```

An existing managed VNC job is reused. Resource arguments only affect a new
job. Use `--restart` when resource values must change or when the script finds
an older VNC job:

```bash
./remote_vnc.sh --restart -p doppelbock -c 8 -g 0 -m 32 -t 4
```

During startup, the script reports stages such as `CHECKING_IMAGE`,
`BUILDING_IMAGE`, `BUILDING_ENVIRONMENT`, `PROVISIONING_ENVIRONMENT`,
`STARTING_VNC`, `STARTING_SSH`, and `READY`. The first mutable launch installs
the development environment and can take substantially longer than later
launches. Existing valid generations are reused.

#### Remote root and file layout

The script reads `REMOTE_SHARED_ROOT` from the third line of
`user_password.txt`. The root is selected in this order:

1. `-r PATH` or `--root PATH`
2. The third line of `user_password.txt`
3. `/scratch/snormanh_lab/shared`

Override it for one run with:

```bash
./remote_vnc.sh --root /path/you/can/write --no-open
```

The writable root contains immutable release files and private per-user state:

```text
${REMOTE_SHARED_ROOT}/remote-vnc/
├── releases/<bundle_sha256>/
│   ├── remote_vnc_job.sh
│   ├── start_vnc.sh
│   ├── start_opencodex.sh
│   ├── build_vnc_image.sh
│   ├── prepare_environment.sh
│   ├── provision_environment.sh
│   ├── environment_common.sh
│   ├── bh-env.sh
│   ├── environment-packages.txt
│   ├── matlab-products.txt
│   ├── ubuntu-vnc-xfce-g3_24.04.def
│   └── bundle.sha256
└── users/${USER}/
    ├── state/
    │   ├── connection.env
    │   ├── vnc-password.txt
    │   └── jobs/<slurm_job_id>/
    ├── logs/
    ├── images/
    ├── bin/bh-env
    └── environments/<name>/
        ├── current -> generations/<generation>/
        ├── generations/<generation>/rootfs/
        ├── home/
        └── checkpoints/
```

The release directory name is the SHA-256 of `bundle.sha256`. Existing releases
are reused only when the manifest hash, every listed file hash, and the file
list all match. A mismatched directory is reported and left unchanged.

User directories use mode `0700`. VNC passwords, SSH keys, logs, and job state
are not stored in another user's directory.

`deploy_remote_tools.sh --vnc` and `--all` copy release and build files but do
not build a SIF on the login node.

#### Image selection and automatic build

The preferred read-only image is:

```text
/scratch/snormanh_lab/shared/remote-vnc/images/ubuntu-vnc-xfce-g3_24.04.sif
```

The job selects an image in this order:

1. Use the shared SIF when it is readable and its SHA-256 is
   `2848904237e27cba487a14af1613d40ea4ab02d3d3808d36daa49cb831a3ffaf`.
2. Use the private SIF under `users/${USER}/images/` when its sidecar checksum
   and runtime checks pass.
3. Build a private SIF inside the current VNC Slurm job.

The Apptainer definition pins the Linux amd64 source manifest instead of the
mutable `24.04` tag. Base-image build cache and temporary data stay in
`SLURM_TMPDIR`; a per-user `flock` prevents concurrent jobs from building the
same image. The image preparation deadline is 30 minutes. Git stores the
definition and checksums, while `.gitignore` excludes SIF binaries.

The selected SIF is the base for the named writable sandbox. Environment build
files stay under the private user directory because the complete MATLAB and
CUDA installation can exceed a compute node's local temporary storage.

Use a different shared image path for another cluster or to test the private
build path:

```bash
REMOTE_VNC_SHARED_IMAGE=/path/to/shared-vnc.sif ./remote_vnc.sh --no-open
```

#### Set the VNC password

The first run under a new remote root creates an eight-character password and
prints its file path. The script never prints the password itself. To replace
it, log in to the cluster, copy the printed path into `password_file`, and enter
the new password without terminal echo:

```bash
ssh -t bluehive3 bash
password_file=/path/printed/by/remote_vnc.sh
umask 077
read -rsp "New VNC password: " vnc_password
printf '\n'
printf '%s\n' "$vnc_password" > "$password_file"
chmod 600 "$password_file"
unset vnc_password
exit
```

Use eight characters or fewer because VNC authentication only uses the first
eight. Restart the VNC job so it regenerates TigerVNC's password file:

```bash
./remote_vnc.sh --restart
```

#### Compute shell and OpenCodex

After startup, connect directly to the allocation:

```bash
ssh blhc3
```

Enter the persistent environment after connecting:

```bash
bh-env shell
```

The VNC desktop itself already runs in this environment. Its desktop contains
launchers for an environment terminal, an admin terminal, Google Chrome,
ChatGPT, and MATLAB R2024b. **Bluehive Host Terminal** remains available for
host modules and programs.

The environment includes Ubuntu development tools, GCC/G++, GFortran, CMake,
Ninja, Git, SSH, screen, tmux, Node.js, npm, OpenCodex 2.39.0, Codex CLI
0.150.1, uv, pixi, CUDA 12.5 development components, Google Chrome, the
ChatGPT Linux desktop app, VNC/XFCE, MathWorks Package Manager (`mpm`), and
MATLAB R2024b with:

- Signal Processing Toolbox
- Statistics and Machine Learning Toolbox
- Parallel Computing Toolbox
- Image Processing Toolbox
- Audio Toolbox
- DSP System Toolbox
- Optimization Toolbox
- Curve Fitting Toolbox
- Deep Learning Toolbox

The CUDA toolkit comes from the container. Apptainer `--nv` injects the driver
and allocated GPU devices from the compute host. MATLAB uses the existing
BlueHive network license file through its `/gpfs/fs1` mount.

#### Install software and preserve changes

Open a writable fakeroot shell from `ssh blhc3`:

```bash
bh-env admin
apt-get update
apt-get install -y ffmpeg
exit
```

Or run one command directly:

```bash
bh-env admin -- apt-get install -y ffmpeg
```

Changes to the sandbox and its home directory persist across VNC jobs. Use a
named environment when separate software stacks are useful:

```bash
./remote_vnc.sh --env experiment --restart
ssh blhc3 -t 'bh-env --env experiment shell'
```

`--immutable` starts the prior read-only SIF workflow, skips sandbox creation,
and does not start the container OpenCodex service. Changing environment name
or mode for an active VNC allocation requires `--restart`.

#### Submit batch scripts in the environment

Run this from a BlueHive login shell or from `ssh blhc3`:

```bash
bh-env sbatch analysis.sh
```

The generated submission wrapper copies every `#SBATCH` directive from
`analysis.sh`. Slurm allocates the resources and establishes the working
directory, then `/bin/bash analysis.sh` runs inside the current environment.
Arguments are forwarded:

```bash
bh-env sbatch analysis.sh subject-01 --overwrite
```

Use `bh-env --env NAME sbatch ...` for another prepared environment.

#### Checkpoint, restore, and rebuild

These commands perform Apptainer image operations and must run inside a Slurm
allocation:

```bash
# Save the current rootfs before a risky change
bh-env checkpoint before-upgrade

# List the checkpoint path, then restore it as a new current generation
bh-env restore 20260903T120000Z-before-upgrade.sif

# Build a clean generation from the verified VNC base image
bh-env rebuild

# Show versions, paths, and the selected generation
bh-env status
```

`restore` and `rebuild` switch the `current` symlink atomically. New `bh-env`
shells and batch jobs use the new generation immediately. Restart the VNC job
when its desktop should move to that generation. Old generations remain in the
private environment directory for manual recovery.

Check that the shell is in the expected Slurm job and can see host resources:

```bash
ssh blhc3 'printf "job=%s node=%s\n" "$SLURM_JOB_ID" "$(hostname -s)"; cat /proc/self/cgroup; type module; test -d /gpfs/fs1; test -d /gpfs/fs2; test -d /scratch'
```

OpenCodex and Codex app-server start automatically with every mutable VNC job.
Check them through the Slurm-bound host shell, whose wrappers enter the running
service instance:

```bash
ssh blhc3 'ocx ready --json'
ssh blhc3 'codex app-server daemon version'
```

The same managed SSH connection exposes the OpenCodex dashboard on the Mac:

```text
http://127.0.0.1:10102
```

The job SSH server permits forwarding only to the active loopback VNC and
OpenCodex ports. `remote_vnc.sh` checks the dashboard over this tunnel before
reporting startup success.

The VNC desktop and service instance use the same sandbox and persistent HOME.
The separate instance exists only so long-lived OpenCodex and app-server
processes, later SSH commands, and Codex App all see the same PID namespace.

The first mutable launch copies the existing host configuration into that
environment's private persistent home. This includes the current OpenCodex
configuration and authentication files, Codex `config.toml`, authentication,
catalog settings, `AGENTS.md`, personal skills, plugin files, memories, and
imported skill sources. Existing destination files are preserved. Runtime PIDs,
sockets, logs, histories, sessions, and response state are excluded. Later
launches use the container copy, so changes made there persist without repeating
this migration.

Startup verifies the Apptainer instance, OpenCodex proxy, and Codex app-server
PIDs against the VNC job's batch cgroup before marking the job ready. Service
state and logs are in
`users/${USER}/state/jobs/<slurm_job_id>/opencodex/`. If either service exits,
the managed VNC job fails and records the reason there.

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

The Slurm launch scripts share these resource options:

- `-a, --cluster CLUSTER`: `bluehive`, `bluehive3`, or `bhward`
- `-p, --partition PARTITION`: Slurm partition
- `-c, --cpus CPUS`: CPU cores
- `-g, --gpus GPUS`: GPUs; use `0` for CPU-only jobs
- `-m, --memory GIB`: memory in GiB
- `-t, --time HOURS`: time limit in hours
- `-w, --node NODE`: request a specific compute node
- `-r, --root PATH`: override `REMOTE_SHARED_ROOT`

`remote_vnc.sh` also accepts:

- `--env NAME`: select or create a persistent environment; default `default`
- `--immutable`: run the original read-only image without preparing a sandbox
- `--restart`: replace the current VNC job
- `--no-open`: do not open macOS Screen Sharing

`tunnel.sh` also accepts `--tool code|cursor` and `-n` to disable logging.
Run any script with `--help` for its current defaults.

## Security Features

- `user_password.txt` is ignored by Git and should use mode `0600`.
- VNC listens on compute-node loopback and reaches the Mac through an SSH local forward.
- The VNC job's external SSH service accepts the configured public key and disables password login.
- Each user's VNC state directory uses mode `0700`; the VNC password file uses mode `0600`.
- SSH host keys are checked before the Mac stores the VNC connection state.
- The script rejects a compute shell, OpenCodex proxy, or Codex app-server process outside the expected Slurm batch cgroup.
- Shared and private SIF files are checked before execution.
- Mutable environments and checkpoints remain under each user's mode `0700` directory.
- Fakeroot applies only to the Apptainer sandbox and retains the user's host permissions.
