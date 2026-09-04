# Remote VNC and mutable environment bundle

`remote_vnc.sh` copies this directory to a SHA-256-named release under
`$REMOTE_SHARED_ROOT/remote-vnc/releases/`. Release files are read-only after
their checksums pass.

`configure_desktop.sh` installs a pinned WhiteSur light theme in the user's
persistent home and applies a versioned XFCE profile without replacing panel
plugins or launchers. `bluehive-aurora.svg` is the bundled 2560x1440 background.
The profile keeps later user edits until its version changes, and supports a
manual `apply --force` refresh.

The VNC Slurm job first checks the shared base image:

```text
/scratch/snormanh_lab/shared/remote-vnc/images/ubuntu-vnc-xfce-g3_24.04.sif
```

If that image is unavailable or invalid, `build_vnc_image.sh` builds a private
copy under `$REMOTE_SHARED_ROOT/remote-vnc/users/$USER/images/` inside the VNC
allocation. The default launch then prepares a named writable sandbox under
`users/$USER/environments/`.

`prepare_environment.sh` creates versioned sandbox generations and calls
`provision_environment.sh` with fakeroot. The recipe installs the package list,
Fish, OpenCodex, Codex CLI, CUDA 12.5 development tools, Chrome, ChatGPT, uv,
pixi, Noto CJK fonts, and MATLAB R2025b with the products in
`matlab-products.txt`. Provisioning verifies that the completed environment has
at least one Chinese-capable font and that MATLAB's splash library has no
unresolved dependencies. A validated `current` symlink activates the generation.
Existing environments remain mutable through `bh-env admin`.

`start_opencodex.sh` copies missing host OpenCodex/Codex settings, credentials,
personal skills, plugins, memories, and imported skill sources into the private
persistent container home on its first launch. It then creates a job-scoped
Apptainer service instance and supervises `ocx start` and the Codex app-server
daemon inside it. Host-side `ocx` and `codex` wrappers join this instance so all
service commands share its PID namespace. The VNC job is reported ready only
after the instance and both services pass their health and cgroup checks.
For mutable environments, `remote_vnc_job_sshd.sh` starts the public SSH server
inside the read-only sandbox. `ssh blhc3` therefore opens Fish directly in the
container, while SFTP, VNC forwarding, and OpenCodex forwarding use the same
Slurm-bound connection. `bluehive-host-shell` returns to the allocation host.
The SSH server uses the fixed `44000-44999` port stored on line 4 of the local
`user_password.txt`; it fails clearly if that port is occupied on the assigned
node instead of silently selecting a different port.
Its external host key is generated once under
`users/$USER/state/remote-ssh/`, protected by a file lock, and reused by later
jobs. The launcher validates the private/public pair before submission, and the
job validates it again before starting `sshd`. The separate host-shell key
remains job-specific because it protects only the container-to-host loopback.
The container commands `bh-env`, `bh-admin`, and `sbatch` proxy short host-side
operations through that private backchannel. The Mac-side launcher verifies the
container identity, interactive PTY, host backchannel, fakeroot admin command,
SFTP, VNC, and `http://127.0.0.1:10102` before reporting success. A private
job-specific `/etc/group` view omits the unmapped `tty` group, allowing the
non-root OpenSSH monitor to assign container PTYs to the user's mapped primary
group.

The VNC launcher defaults to `2560x1440`, accepts a validated geometry from the
Mac launcher, and records it in both job and connection state. It explicitly
checks TigerVNC's bidirectional text clipboard, desktop-resize, and blacklist
parameters after startup. RFB remains loopback-only with `VncAuth`, so macOS
Screen Sharing reaches it through the managed SSH tunnel.

`bh-env.sh` provides interactive shells, command execution, Slurm submission,
checkpoints, restore, and clean rebuilds. `bh-env sbatch` copies the original
`#SBATCH` directives and starts the whole Bash script inside the sandbox. VNC
environment terminals and interactive `bh-env` shells default to Fish; host
terminal and batch execution remain Bash-based. VNC terminal and MATLAB
launchers enter the current generation through the allocation's private SSH
service, allowing a running desktop to use software installed after its initial
Apptainer mount was created. From the direct container SSH shell, `bh-env shell`
or `bh-env exec -- COMMAND` also starts a fresh mount. Restart the VNC job when
all long-running container namespaces should reload a changed rootfs.

Passwords, SSH keys, logs, environments, checkpoints, and job state remain
under the same private user directory with mode `0700`. The persistent external
SSH private host key uses mode `0600`.

The canonical shared image SHA-256 is recorded in
`ubuntu-vnc-xfce-g3_24.04.sha256`. The definition pins the Linux amd64 OCI
manifest rather than using a mutable Docker tag.
