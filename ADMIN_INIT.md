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

## 1. 本地凭据文件

在本地脚本目录创建或更新 `user_password.txt`：

```text
your_username
your_password
/scratch/snormanh_lab/shared
```

第三行是远端工具根目录。要放到其他位置，直接把第三行改成目标路径，或者运行脚本时用 `--root /path/to/shared-tools` 覆盖。

## 2. SSH 配置

确保本机 `~/.ssh/config` 至少包含登录节点和 compute host。`remote_sshd.sh` 会自动改写 compute host 的 `Hostname` 和 `Port`：

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

启动 Dropbear SSHD job，并自动更新本机 compute host 的 SSH 配置：

```bash
./remote_sshd.sh -a bluehive3 -p doppelbock -c 16 -g 1 -m 256 -t 24
```

该脚本会先自动确保远端 Dropbear 已部署且 host keys 已生成，然后提交 `my_sshd` Slurm job。启动后会从 `~/logs/dropbear.log` 读取端口和节点，并调用 `update_ssh_config.sh` 写入 `~/.ssh/config`。

## 8. 验证

检查远端工具：

```bash
ssh bluehive3 'ls -l /scratch/snormanh_lab/shared/code /scratch/snormanh_lab/shared/cursor /scratch/snormanh_lab/shared/dropbear/sbin/dropbear'
```

检查 Dropbear host keys：

```bash
ssh bluehive3 'ls -l /scratch/snormanh_lab/shared/dropbear/.ssh'
```

检查 tunnel job：

```bash
ssh bluehive3 'squeue -u "$USER" -O jobarrayid:18,name:32,nodelist:20,state:12'
```

## 9. 常见问题

- 如果远端没有 `curl` 或 `wget`，VS Code/Cursor 自动下载会失败，需要管理员先安装其中一个工具，或手工把二进制放到 shared root。
- 如果 `known_hosts` 提示 Dropbear host key changed，这是重新生成 host key 后的正常现象。清理对应主机和端口的旧条目后重连。
- 如果不想部署 Cursor，只用默认 VS Code tunnel 即可；`remote_sshd.sh` 不依赖 Cursor。
