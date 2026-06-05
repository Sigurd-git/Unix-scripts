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

## 1. Local Credential File

Create or update `user_password.txt` in the local script directory:

```text
your_username
your_password
/scratch/snormanh_lab/shared
```

The third line is the remote tool root. To use a different location, change the third line directly, or override it at runtime with `--root /path/to/shared-tools`.

## 2. SSH Configuration

Make sure your local `~/.ssh/config` contains at least the login node and the compute host. `remote_sshd.sh` automatically rewrites the compute host `Hostname` and `Port`:

```sshconfig
Host bluehive3
    Hostname bluehive3.circ.rochester.edu
    User your_username
    ControlMaster auto
    ControlPath /tmp/ssh_bluehive3

Host bluehive_compute3
    Hostname bhg0049
    User your_username
    ProxyJump bluehive3
```

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

Start a Dropbear SSHD job and automatically update the local compute host SSH config:

```bash
./remote_sshd.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 24
```

The script first ensures remote Dropbear is deployed and host keys exist, then submits the `my_sshd` Slurm job. After startup, it reads the port and node from `~/logs/dropbear.log`, then calls `update_ssh_config.sh` to update `~/.ssh/config`.

## 8. Verification

Check remote tools:

```bash
ssh bluehive3 'ls -l /scratch/snormanh_lab/shared/code /scratch/snormanh_lab/shared/cursor /scratch/snormanh_lab/shared/dropbear/sbin/dropbear'
```

Check Dropbear host keys:

```bash
ssh bluehive3 'ls -l /scratch/snormanh_lab/shared/dropbear/.ssh'
```

Check tunnel jobs:

```bash
ssh bluehive3 'squeue -u "$USER" -O jobarrayid:18,name:32,nodelist:20,state:12'
```

## 9. Common Issues

- If the remote host has neither `curl` nor `wget`, automatic VS Code/Cursor download fails. Ask the administrator to install one of them, or manually place the binary in the shared root.
- If `known_hosts` reports that the Dropbear host key changed, that is expected after regenerating host keys. Remove the old host and port entry, then reconnect.
- If you do not want Cursor, use the default VS Code tunnel only; `remote_sshd.sh` does not depend on Cursor.
