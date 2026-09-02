# Remote VNC bundle

`remote_vnc.sh` copies this directory to a SHA-256-named release under
`$REMOTE_SHARED_ROOT/remote-vnc/releases/`. Release files are read-only after
their checksums pass.

The VNC Slurm job first checks the shared image:

```text
/scratch/snormanh_lab/shared/remote-vnc/images/ubuntu-vnc-xfce-g3_24.04.sif
```

If that image is unavailable or invalid, `build_vnc_image.sh` builds a private
copy under `$REMOTE_SHARED_ROOT/remote-vnc/users/$USER/images/` inside the VNC
allocation. Passwords, SSH keys, logs, and job state remain under the same
private user directory with mode `0700`.

The canonical shared image SHA-256 is recorded in
`ubuntu-vnc-xfce-g3_24.04.sha256`. The definition pins the Linux amd64 OCI
manifest rather than using a mutable Docker tag.
