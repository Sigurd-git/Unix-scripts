<p align="right">
  <a href="./ADMIN_INIT.en.md"><kbd>English Version</kbd></a>
</p>

# 管理员初始化教程

本教程用于在新集群或新共享目录上初始化这些脚本需要的远端工具。默认远端目录是：

```bash
/scratch/snormanh_lab/shared
```

该目录下会放这些内容：

- `code`: VS Code standalone CLI，用于默认的 `code tunnel`
- `cursor`: Cursor tunnel CLI，用于可选的 `cursor tunnel`
- `dropbear/`: 用户态 Dropbear SSHD，包括 `sbin/dropbear`、`bin/dropbearkey` 和服务端 host keys
- `remote-vnc/`: VNC 启动脚本、每位用户的私有状态，以及没有公共 SIF 时构建的用户镜像

## 1. 本地首次运行

无需创建凭据文件。直接运行任意入口，例如：

```bash
./deploy_remote_tools.sh --all
```

第一次运行会询问 BlueHive 用户名、远端工具根目录和可选密码。新用户的
远端根目录默认为 `/scratch/<username>`。脚本会询问是否把用户名、根目录
和自动生成的固定 VNC 端口保存到
`~/.config/unix-scripts/config`，并单独询问是否保存明文密码。配置文件权限
固定为 `0600`。不保存密码时，OpenSSH 会在建立新登录连接时正常询问。

旧的四行 `user_password.txt` 仍可直接读取，已有用户无需迁移。

## 2. SSH 连接

所有入口都使用完整主机名、明确的用户和项目管理的 ControlMaster，无需
手写 SSH 配置。连接后会自动更新 `~/.ssh/config` 顶部带标记的集群配置，
备份并保留原有内容，让普通 `ssh` 和使用系统 OpenSSH 的 App 复用相同的
连接。进入登录节点使用：

```bash
./cluster_ssh.sh --cluster bluehive3
```

VNC 作业启动后，使用 `blhc3` 或 `ssh blhc3` 进入容器。已有作业可以运行
`./sync_ssh_config.sh -a bluehive3` 更新这些别名。

## 3. 一键部署远端工具

部署 VS Code CLI、Cursor tunnel CLI 和 Dropbear：

```bash
./deploy_remote_tools.sh -a bluehive3 --all
```

只部署其中一部分：

```bash
./deploy_remote_tools.sh -a bluehive3 --code
./deploy_remote_tools.sh -a bluehive3 --cursor
./deploy_remote_tools.sh -a bluehive3 --dropbear
./deploy_remote_tools.sh -a bluehive3 --vnc
```

使用非默认远端目录：

```bash
./deploy_remote_tools.sh -a bluehive3 --root /scratch/snormanh_lab/shared --all
```

## 4. Dropbear 初始化细节

`deploy_remote_tools.sh --dropbear` 会做三件事：

1. 如果远端没有 `$REMOTE_SHARED_ROOT/dropbear/sbin/dropbear`，把本地 `dropbear/` 目录复制到远端。
2. 如果远端 `dropbear/.ssh` 不存在或 host key 缺失，自动生成：
   - `dropbear_rsa_host_key`
   - `dropbear_ecdsa_host_key`
   - `dropbear_ed25519_host_key`
3. 设置权限：`.ssh` 为 `700`，私钥为 `600`，公钥为 `644`。

这些 host keys 是临时 SSH 服务的服务端身份，不是客户端登录私钥。删除后可以重新生成，但客户端可能需要清理旧的 `known_hosts` 条目。

## 5. VS Code tunnel

`tunnel.sh` 现在默认使用 VS Code CLI：

```bash
./tunnel.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 12
```

它会先检查 `$REMOTE_SHARED_ROOT/code`，不存在就自动下载 VS Code Linux x64 CLI 到该路径，然后启动：

```bash
code tunnel --accept-server-license-terms --verbose --name bluehive3V
```

首次使用时，日志里可能会出现设备登录码，需要按 VS Code tunnel 的提示完成 GitHub 或 Microsoft 登录。

## 6. Cursor tunnel

Cursor tunnel 保留为显式选项：

```bash
./tunnel.sh -a bluehive3 --tool cursor -p doppelbock -c 16 -g 1 -m 256 -t 12
```

也可以写成：

```bash
./tunnel.sh -a bluehive3 --cursor
```

它会先检查 `$REMOTE_SHARED_ROOT/cursor`，不存在就尝试从 Cursor tunnel CLI 下载端点部署。Cursor 的 tunnel CLI 下载端点不是 VS Code 那样的长期稳定公开 API；如果 Cursor 端点变动，先改用默认的 VS Code tunnel。

## 7. Remote SSHD

启动 Dropbear SSHD job，并保存本机连接状态：

```bash
./remote_sshd.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 24
```

该脚本会先自动确保远端 Dropbear 已部署且 host keys 已生成，然后提交
`my_sshd` Slurm job。启动后会从 `~/logs/dropbear.log` 读取端口和节点，
保存连接状态，然后用 `blhc3 --service sshd` 进入该作业。

## 8. Remote VNC

VNC 使用以下公共只读镜像：

```text
/scratch/snormanh_lab/shared/remote-vnc/images/ubuntu-vnc-xfce-g3_24.04.sif
```

启动一个独立的 VNC Slurm 作业：

```bash
./remote_vnc.sh
```

脚本会在 `$REMOTE_SHARED_ROOT/remote-vnc/releases/` 检查带 SHA-256 的脚本版本。缺少时才会复制。密码、SSH 密钥、日志和作业状态保存在：

```text
$REMOTE_SHARED_ROOT/remote-vnc/users/$USER/
```

`deploy_remote_tools.sh --vnc` 和 `--all` 只复制这些文件，不会在登录节点构建 SIF。

公共 SIF 无法读取或校验失败时，VNC 作业会在 Slurm 分配内用仓库附带的 Apptainer 定义构建用户镜像。可以为一次运行指定其他目录：

```bash
./remote_vnc.sh --root /path/you/can/write --no-open
```

启动完成后，`blhc3` 会进入同一个 VNC Slurm 作业。可写环境会默认在作业
专属的 Apptainer service instance 中启动 OpenCodex 和 Codex app-server；
`blhc3` 使用的 `ocx` 和 `codex` 会进入同一个 instance。首次启动还会把
当前用户的配置、认证、个人 skills、plugins 和 memories 复制到容器的私有
持久 HOME。

## 9. 验证

检查远端工具：

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'ls -l /scratch/snormanh_lab/shared/code /scratch/snormanh_lab/shared/cursor /scratch/snormanh_lab/shared/dropbear/sbin/dropbear'
```

检查 Dropbear host keys：

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'ls -l /scratch/snormanh_lab/shared/dropbear/.ssh'
```

检查 tunnel job：

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'squeue -u "$USER" -O jobarrayid:18,name:32,nodelist:20,state:12'
```

检查 VNC 用户目录权限：

```bash
./cluster_ssh.sh --cluster bluehive3 -- 'stat -c "%a %n" /scratch/snormanh_lab/shared/remote-vnc/users/"$USER"'
```

## 10. 常见问题

- 如果远端没有 `curl` 或 `wget`，VS Code/Cursor 自动下载会失败，需要管理员先安装其中一个工具，或手工把二进制放到 shared root。
- 如果 `known_hosts` 提示 Dropbear host key changed，这是重新生成 host key 后的正常现象。清理对应主机和端口的旧条目后重连。
- 如果不想部署 Cursor，只用默认 VS Code tunnel 即可；`remote_sshd.sh` 不依赖 Cursor。
