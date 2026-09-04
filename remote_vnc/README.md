# Remote VNC and mutable environment bundle

`remote_vnc.sh` copies this directory to a SHA-256-named release under
`$REMOTE_SHARED_ROOT/remote-vnc/releases/`. Release files are read-only after
their checksums pass.

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
OpenCodex, Codex CLI, CUDA 12.5 development tools, Chrome, ChatGPT, uv, pixi,
and MATLAB R2024b with the products in `matlab-products.txt`. A validated
`current` symlink activates the generation. Existing environments remain
mutable through `bh-env admin`.

`start_opencodex.sh` copies missing host OpenCodex/Codex settings, credentials,
personal skills, plugins, memories, and imported skill sources into the private
persistent container home on its first launch. It then creates a job-scoped
Apptainer service instance and supervises `ocx start` and the Codex app-server
daemon inside it. Host-side `ocx` and `codex` wrappers join this instance so all
service commands share its PID namespace. The VNC job is reported ready only
after the instance and both services pass their health and cgroup checks.
`remote_vnc_job_sshd.sh` permits forwarding only to the active VNC and
OpenCodex loopback ports; the Mac-side launcher verifies the dashboard through
`http://127.0.0.1:10102` before reporting success.

`bh-env.sh` provides interactive shells, command execution, Slurm submission,
checkpoints, restore, and clean rebuilds. `bh-env sbatch` copies the original
`#SBATCH` directives and starts the whole Bash script inside the sandbox.

Passwords, SSH keys, logs, environments, checkpoints, and job state remain
under the same private user directory with mode `0700`.

The canonical shared image SHA-256 is recorded in
`ubuntu-vnc-xfce-g3_24.04.sha256`. The definition pins the Linux amd64 OCI
manifest rather than using a mutable Docker tag.
