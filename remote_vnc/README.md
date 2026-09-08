# Remote VNC and mutable environment bundle

`remote_vnc.sh` copies this directory to a SHA-256-named release under
`$REMOTE_SHARED_ROOT/remote-vnc/releases/`. Release files are read-only after
their checksums pass.

The Mac launcher holds `users/$USER/state/launch.lock` while checking,
replacing, and waiting for a job. A concurrent launch fails with a retry message.
Each allocation also holds `state/allocation.lock` until its services stop,
including jobs submitted directly with `sbatch`. This prevents two jobs from
changing the same desktop files, OpenCodex state, or app-server sockets.

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
service commands share its PID namespace. `environment_common.sh` keeps
OpenCodex configuration and app-server sockets private, but mounts the host
Codex session directories, indexes, attachments, artifacts, and writer locks
into every container and points `CODEX_SQLITE_HOME` to the host `.codex` state.
The host is therefore the canonical live session store. The VNC job is reported
ready only after the instance, both services, and the host-session mounts pass
their health and cgroup checks.
After startup, the daemon monitor checks the PID file and Slurm cgroup without
opening repeated RPC connections. A busy daemon can time out an RPC status
query while its process is still running. A missing process gets 60 seconds to
return during a restart before the launcher treats it as a service failure.
For mutable environments, `remote_vnc_job_sshd.sh` starts the public SSH server
inside the read-only sandbox. `blhc3` therefore opens Fish directly in the
container, while SFTP, VNC forwarding, and OpenCodex forwarding use the same
Slurm-bound connection. `bluehive-host-shell` returns to the allocation host.
The SSH server uses a fixed `44000-44999` port derived from the remote username
and stored in the local managed profile; it fails clearly if that port is
occupied on the assigned node instead of silently selecting a different port.
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

The VNC launcher defaults to an initial `2560x1440`, accepts a validated
geometry from the Mac launcher, and records it in both job and connection
state. The macOS TigerVNC launcher requests the current full-screen viewport
through remote resize and disables JPEG so text remains lossless instead of
scaling a larger, lossy framebuffer. The server remaps incoming `Alt_L` to
`Super_L` because TigerVNC sends the Mac left Command key as `Alt_L`; the right
Command key already arrives as `Super_L`. It explicitly checks the clipboard,
desktop-resize, key-remap, and blacklist parameters after startup. RFB remains
loopback-only with `VncAuth`, so macOS Screen Sharing reaches it through the
managed SSH tunnel.

`configure_desktop.sh` owns the persistent XFCE profile and registers Super-key
application shortcuts. `macos_shortcut.sh` uses the focused window class to
translate those actions: XFCE Terminal receives its Control+Shift variants,
while regular GUI applications receive Control variants. This preserves shell
Control+C, Control+Z, and Control+S semantics. `xdotool` is part of newly built
mutable environments; an existing mutable generation needs it installed once
before the profile reports `MACOS_SHORTCUTS=READY`.

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
