<p align="right">
  <a href="./ADMIN_INIT.md"><kbd>中文版本</kbd></a>
</p>

# Administrator Initialization Guide

This guide initializes the remote tools required by these scripts on a new cluster or a new shared directory. The default remote directory is:

```bash
/scratch/snormanh_lab/shared
```

This directory stores:

- `code`: VS Code standalone CLI, used by the default `code tunnel`
- `cursor`: Cursor tunnel CLI, used by the optional `cursor tunnel`
- `dropbear/`: user-space Dropbear SSHD, including `sbin/dropbear`, `bin/dropbearkey`, and server host keys
- `remote-vnc/`: VNC launch files, private per-user state, and user-built images when the shared SIF is unavailable

## 1. First Local Run

No credential file needs to be created. Run any entry point directly, for
example:

```bash
./deploy_remote_tools.sh --all
```

The first run asks for the BlueHive username, remote tool root, and an optional
password. A new user's root defaults to `/scratch/<username>`. The script asks
whether to save the username, root, and derived fixed VNC port under
`~/.config/unix-scripts/config`, then asks separately whether the plaintext
password should be included. The file always uses mode `0600`. When no password
is saved, OpenSSH prompts while establishing a new login connection.

The historical four-line `user_password.txt` format remains supported.

## 2. SSH Connections

Every entry point uses the full hostname, explicit user, and a project-managed
ControlMaster. It neither reads nor rewrites `~/.ssh/config`. Open a login-node
shell with:

```bash
./cluster_ssh.sh --cluster bluehive3
```

After a VNC job starts, use the repository's `blhc3` command to enter its
container.

## 3. One-Command Remote Tool Deployment

Deploy VS Code CLI, Cursor tunnel CLI, and Dropbear:

```bash
./deploy_remote_tools.sh -a bluehive3 --all
```

Deploy only selected tools:

```bash
./deploy_remote_tools.sh -a bluehive3 --code
./deploy_remote_tools.sh -a bluehive3 --cursor
./deploy_remote_tools.sh -a bluehive3 --dropbear
./deploy_remote_tools.sh -a bluehive3 --vnc
```

Use a non-default remote directory:

```bash
./deploy_remote_tools.sh -a bluehive3 --root /scratch/snormanh_lab/shared --all
```

## 4. Dropbear Initialization Details

`deploy_remote_tools.sh --dropbear` does three things:

1. If `$REMOTE_SHARED_ROOT/dropbear/sbin/dropbear` does not exist on the remote host, it copies the local `dropbear/` directory to the remote host.
2. If remote `dropbear/.ssh` does not exist or any host key is missing, it generates:
   - `dropbear_rsa_host_key`
   - `dropbear_ecdsa_host_key`
   - `dropbear_ed25519_host_key`
3. It sets permissions: `.ssh` to `700`, private keys to `600`, and public keys to `644`.

These host keys identify the temporary SSH server. They are not client login private keys. You can regenerate them after deletion, but clients may need old entries removed from `known_hosts`.

## 5. VS Code Tunnel

`tunnel.sh` now uses VS Code CLI by default:

```bash
./tunnel.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 12
```

It first checks `$REMOTE_SHARED_ROOT/code`. If missing, it downloads the VS Code Linux x64 CLI to that path, then starts:

```bash
code tunnel --accept-server-license-terms --verbose --name bluehive3V
```

On first use, the log may show a device login code. Follow the VS Code tunnel prompt to complete GitHub or Microsoft authentication.

## 6. Cursor Tunnel

Cursor tunnel remains available as an explicit option:

```bash
./tunnel.sh -a bluehive3 --tool cursor -p doppelbock -c 16 -g 1 -m 256 -t 12
```

You can also use:

```bash
./tunnel.sh -a bluehive3 --cursor
```

It first checks `$REMOTE_SHARED_ROOT/cursor`. If missing, it tries to deploy from the Cursor tunnel CLI download endpoint. Cursor's tunnel CLI download endpoint is not as stable as VS Code's long-term public CLI URL; if the Cursor endpoint changes, use the default VS Code tunnel first.

## 7. Remote SSHD

Start a Dropbear SSHD job and save its local connection state:

```bash
./remote_sshd.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 24
```

The script first ensures remote Dropbear is deployed and host keys exist, then
submits the `my_sshd` Slurm job. After startup, it reads the port and node from
`~/logs/dropbear.log`, saves the connection state, and connects with
`blhc3 --service sshd`.

## 8. Remote VNC

VNC prefers this shared read-only image:

```text
/scratch/snormanh_lab/shared/remote-vnc/images/ubuntu-vnc-xfce-g3_24.04.sif
```

Start an independent VNC Slurm job:

```bash
./remote_vnc.sh
```

The script checks for a SHA-256-named script release under
`$REMOTE_SHARED_ROOT/remote-vnc/releases/` and copies it only when absent.
Passwords, SSH keys, logs, and job state stay under:

```text
$REMOTE_SHARED_ROOT/remote-vnc/users/$USER/
```

`deploy_remote_tools.sh --vnc` and `--all` copy these files but do not build a
SIF on the login node.

If the shared SIF is unreadable or fails validation, the VNC job builds a
private image inside its Slurm allocation from the pinned Apptainer definition.
Override the writable remote root for one run with:

```bash
./remote_vnc.sh --root /path/you/can/write --no-open
```

After startup, `blhc3` enters the same VNC Slurm allocation. A mutable
environment starts OpenCodex and Codex app-server in a job-scoped Apptainer
service instance by default; `ocx` and `codex` invoked through `blhc3` join
that same instance. Its first launch also copies the current user's
configuration, authentication, personal skills, plugins, and memories into the
container's private persistent home.

## 9. Verification

Check remote tools:

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'ls -l /scratch/snormanh_lab/shared/code /scratch/snormanh_lab/shared/cursor /scratch/snormanh_lab/shared/dropbear/sbin/dropbear'
```

Check Dropbear host keys:

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'ls -l /scratch/snormanh_lab/shared/dropbear/.ssh'
```

Check tunnel jobs:

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'squeue -u "$USER" -O jobarrayid:18,name:32,nodelist:20,state:12'
```

Check the private VNC directory permissions:

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'stat -c "%a %n" /scratch/snormanh_lab/shared/remote-vnc/users/"$USER"'
```

## 10. Common Issues

- If the remote host has neither `curl` nor `wget`, automatic VS Code/Cursor download fails. Ask the administrator to install one of them, or manually place the binary in the shared root.
- If `known_hosts` reports that the Dropbear host key changed, that is expected after regenerating host keys. Remove the old host and port entry, then reconnect.
- If you do not want Cursor, use the default VS Code tunnel only; `remote_sshd.sh` does not depend on Cursor.
