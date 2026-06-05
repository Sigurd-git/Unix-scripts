#!/bin/bash

remote_tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SHARED_ROOT_DEFAULT="/scratch/snormanh_lab/shared"
REMOTE_SHARED_ROOT="${REMOTE_SHARED_ROOT:-$REMOTE_SHARED_ROOT_DEFAULT}"

remote_tools_require_context() {
    if [ -z "$CLUSTER" ] || [ -z "$HOSTNAME" ] || [ -z "$USER" ]; then
        echo "Error: CLUSTER, HOSTNAME, and USER must be set before using remote_tools.sh" >&2
        return 1
    fi
}

remote_tools_ssh() {
    remote_tools_require_context || return 1
    ssh -o ControlMaster=auto \
        -o ControlPath="/tmp/ssh_$CLUSTER" \
        -o StrictHostKeyChecking=no \
        -T "$USER@$HOSTNAME" "$@"
}

remote_tools_ssh_bash() {
    remote_tools_require_context || return 1
    ssh -o ControlMaster=auto \
        -o ControlPath="/tmp/ssh_$CLUSTER" \
        -o StrictHostKeyChecking=no \
        -T "$USER@$HOSTNAME" \
        "REMOTE_SHARED_ROOT=$(printf "%q" "$REMOTE_SHARED_ROOT") bash -s"
}

ensure_remote_vscode_cli() {
    remote_tools_require_context || return 1

    if remote_tools_ssh "test -x $(printf "%q" "$REMOTE_SHARED_ROOT/code")"; then
        echo "VS Code CLI already exists: $REMOTE_SHARED_ROOT/code"
        return 0
    fi

    echo "Deploying VS Code CLI to $REMOTE_SHARED_ROOT/code..."
    remote_tools_ssh_bash <<'ENDSSH'
set -euo pipefail

mkdir -p "$REMOTE_SHARED_ROOT"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vscode-cli.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

download_url="https://update.code.visualstudio.com/latest/cli-linux-x64/stable"
archive="$tmp_dir/code_cli.tar.gz"

if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 -o "$archive" "$download_url"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$archive" "$download_url"
else
    echo "Error: neither curl nor wget exists on the remote host" >&2
    exit 1
fi

tar -xzf "$archive" -C "$tmp_dir"
code_bin="$(find "$tmp_dir" -type f -name code | head -n 1)"
if [ -z "$code_bin" ]; then
    echo "Error: downloaded VS Code CLI archive did not contain an executable named code" >&2
    exit 1
fi

cp "$code_bin" "$REMOTE_SHARED_ROOT/code"
chmod 755 "$REMOTE_SHARED_ROOT/code"
"$REMOTE_SHARED_ROOT/code" --version | head -n 1 || true
ENDSSH
}

ensure_remote_cursor_cli() {
    remote_tools_require_context || return 1

    if remote_tools_ssh "test -x $(printf "%q" "$REMOTE_SHARED_ROOT/cursor")"; then
        echo "Cursor tunnel CLI already exists: $REMOTE_SHARED_ROOT/cursor"
        return 0
    fi

    echo "Deploying Cursor tunnel CLI to $REMOTE_SHARED_ROOT/cursor..."
    remote_tools_ssh_bash <<'ENDSSH'
set -euo pipefail

mkdir -p "$REMOTE_SHARED_ROOT"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cursor-cli.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

download_url="https://api2.cursor.sh/updates/download-latest?os=cli-alpine-x64"
archive="$tmp_dir/cursor_cli.tar.gz"

if command -v curl >/dev/null 2>&1; then
    curl -Lk --fail --retry 3 -o "$archive" "$download_url"
elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -O "$archive" "$download_url"
else
    echo "Error: neither curl nor wget exists on the remote host" >&2
    exit 1
fi

tar -xzf "$archive" -C "$tmp_dir"
cursor_bin="$(find "$tmp_dir" -type f -name cursor | head -n 1)"
if [ -z "$cursor_bin" ]; then
    echo "Error: downloaded Cursor CLI archive did not contain an executable named cursor" >&2
    exit 1
fi

cp "$cursor_bin" "$REMOTE_SHARED_ROOT/cursor"
chmod 755 "$REMOTE_SHARED_ROOT/cursor"
"$REMOTE_SHARED_ROOT/cursor" --version | head -n 1 || true
ENDSSH
}

copy_remote_dropbear_tree() {
    remote_tools_require_context || return 1

    if [ ! -d "$remote_tools_dir/dropbear" ]; then
        echo "Error: local dropbear directory not found at $remote_tools_dir/dropbear" >&2
        return 1
    fi

    echo "Copying local dropbear tree to $REMOTE_SHARED_ROOT/dropbear..."
    tar -C "$remote_tools_dir" -czf - dropbear | ssh -o ControlMaster=auto \
        -o ControlPath="/tmp/ssh_$CLUSTER" \
        -o StrictHostKeyChecking=no \
        -T "$USER@$HOSTNAME" \
        "mkdir -p $(printf "%q" "$REMOTE_SHARED_ROOT") && tar -xzf - -C $(printf "%q" "$REMOTE_SHARED_ROOT")"
}

ensure_remote_dropbear() {
    remote_tools_require_context || return 1

    if ! remote_tools_ssh "test -x $(printf "%q" "$REMOTE_SHARED_ROOT/dropbear/sbin/dropbear") && test -x $(printf "%q" "$REMOTE_SHARED_ROOT/dropbear/bin/dropbearkey")"; then
        copy_remote_dropbear_tree || return 1
    else
        echo "Dropbear already exists: $REMOTE_SHARED_ROOT/dropbear"
    fi

    echo "Ensuring Dropbear host keys exist under $REMOTE_SHARED_ROOT/dropbear/.ssh..."
    remote_tools_ssh_bash <<'ENDSSH'
set -euo pipefail

dropbear_dir="$REMOTE_SHARED_ROOT/dropbear"
cd "$dropbear_dir"

if [ ! -x ./bin/dropbearkey ]; then
    echo "Error: $dropbear_dir/bin/dropbearkey is missing or not executable" >&2
    exit 1
fi

mkdir -p .ssh
chmod 700 .ssh

if [ ! -s .ssh/dropbear_rsa_host_key ]; then
    ./bin/dropbearkey -t rsa -s 4096 -f .ssh/dropbear_rsa_host_key
fi

if [ ! -s .ssh/dropbear_ecdsa_host_key ]; then
    ./bin/dropbearkey -t ecdsa -f .ssh/dropbear_ecdsa_host_key
fi

if [ ! -s .ssh/dropbear_ed25519_host_key ]; then
    ./bin/dropbearkey -t ed25519 -f .ssh/dropbear_ed25519_host_key
fi

./bin/dropbearkey -y -f .ssh/dropbear_rsa_host_key | awk '/^ssh-rsa /{print; exit}' > .ssh/dropbear_rsa_host_key.pub
./bin/dropbearkey -y -f .ssh/dropbear_ecdsa_host_key | awk '/^ecdsa-/{print; exit}' > .ssh/dropbear_ecdsa_host_key.pub
./bin/dropbearkey -y -f .ssh/dropbear_ed25519_host_key | awk '/^ssh-ed25519 /{print; exit}' > .ssh/dropbear_ed25519_host_key.pub

chmod 600 .ssh/dropbear_*_host_key
chmod 644 .ssh/dropbear_*_host_key.pub
ENDSSH
}
