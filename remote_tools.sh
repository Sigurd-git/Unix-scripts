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

remote_tools_control_path() {
    printf '%s\n' "${REMOTE_TOOLS_CONTROL_PATH:-/tmp/ssh_$CLUSTER}"
}

remote_tools_ssh() {
    local control_path

    remote_tools_require_context || return 1
    control_path="$(remote_tools_control_path)"
    ssh -o ControlMaster=auto \
        -o ControlPath="$control_path" \
        -o StrictHostKeyChecking=no \
        -T "$USER@$HOSTNAME" "$@"
}

remote_tools_ssh_bash() {
    local control_path

    remote_tools_require_context || return 1
    control_path="$(remote_tools_control_path)"
    ssh -o ControlMaster=auto \
        -o ControlPath="$control_path" \
        -o StrictHostKeyChecking=no \
        -T "$USER@$HOSTNAME" \
        "REMOTE_SHARED_ROOT=$(printf "%q" "$REMOTE_SHARED_ROOT") bash -s"
}

remote_tools_ssh_bash_args() {
    local control_path
    local remote_command="/bin/bash -s --"
    local argument

    remote_tools_require_context || return 1
    control_path="$(remote_tools_control_path)"
    for argument in "$@"; do
        remote_command+=" $(printf '%q' "$argument")"
    done

    ssh -o ControlMaster=auto \
        -o ControlPath="$control_path" \
        -o StrictHostKeyChecking=no \
        -T "$USER@$HOSTNAME" \
        "$remote_command"
}

remote_tools_ssh_command() {
    local control_path
    local remote_command=""
    local argument

    remote_tools_require_context || return 1
    control_path="$(remote_tools_control_path)"
    for argument in "$@"; do
        remote_command+=" $(printf '%q' "$argument")"
    done

    ssh -o ControlMaster=auto \
        -o ControlPath="$control_path" \
        -o StrictHostKeyChecking=no \
        -T "$USER@$HOSTNAME" \
        "${remote_command# }"
}

remote_tools_local_sha256() {
    local requested_file="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$requested_file" | awk '{ print $1; exit }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$requested_file" | awk '{ print $1; exit }'
    else
        echo "Error: neither sha256sum nor shasum is available" >&2
        return 1
    fi
}

remove_remote_vnc_incoming_directory() {
    local remote_incoming_directory="$1"

    remote_tools_ssh_bash_args "$remote_incoming_directory" <<'REMOTE_CLEANUP'
set -Eeuo pipefail
incoming_directory="$1"
case "$incoming_directory" in
    */remote-vnc/releases/.incoming.*) ;;
    *)
        printf 'Refusing to remove an unexpected VNC path: %s\n' \
            "$incoming_directory" >&2
        exit 2
        ;;
esac
if [[ -d "$incoming_directory" ]]; then
    find "$incoming_directory" -type d -exec chmod u+rwx {} +
    rm -rf -- "$incoming_directory"
elif [[ -e "$incoming_directory" ]]; then
    rm -f -- "$incoming_directory"
fi
REMOTE_CLEANUP
}

verify_local_vnc_bundle() {
    local bundle_directory="$remote_tools_dir/remote_vnc"
    local bundle_manifest="$bundle_directory/bundle.sha256"
    local actual_files
    local manifest_files

    if [ ! -d "$bundle_directory" ]; then
        echo "Error: local VNC bundle not found at $bundle_directory" >&2
        return 1
    fi
    if [ ! -r "$bundle_manifest" ]; then
        echo "Error: VNC bundle manifest is missing: $bundle_manifest" >&2
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        if ! (cd "$bundle_directory" && sha256sum -c bundle.sha256 >/dev/null); then
            echo "Error: VNC bundle checksum validation failed: $bundle_manifest" >&2
            return 1
        fi
    elif command -v shasum >/dev/null 2>&1; then
        if ! (cd "$bundle_directory" &&
              shasum -a 256 -c bundle.sha256 >/dev/null); then
            echo "Error: VNC bundle checksum validation failed: $bundle_manifest" >&2
            return 1
        fi
    else
        echo "Error: neither sha256sum nor shasum is available" >&2
        return 1
    fi

    actual_files="$(
        cd "$bundle_directory" &&
            find . -type f ! -path './bundle.sha256' -print |
            sed 's|^\./||' |
            LC_ALL=C sort
    )"
    manifest_files="$(
        awk '
            NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 2 }
            { print $2 }
        ' "$bundle_manifest" 2>/dev/null | LC_ALL=C sort
    )" || {
        echo "Error: VNC bundle manifest has an invalid entry: $bundle_manifest" >&2
        return 1
    }
    if [ "$actual_files" != "$manifest_files" ]; then
        echo "Error: VNC bundle files do not match $bundle_manifest" >&2
        return 1
    fi
}

ensure_remote_vnc_bundle() {
    local bundle_directory="$remote_tools_dir/remote_vnc"
    local bundle_manifest="$bundle_directory/bundle.sha256"
    local bundle_digest
    local remote_vnc_root
    local remote_release_directory
    local remote_incoming_directory
    local release_state

    remote_tools_require_context || return 1
    verify_local_vnc_bundle || return 1

    bundle_digest="$(remote_tools_local_sha256 "$bundle_manifest")" || return 1
    remote_vnc_root="${REMOTE_SHARED_ROOT%/}/remote-vnc"
    remote_release_directory="$remote_vnc_root/releases/$bundle_digest"
    remote_incoming_directory="$remote_vnc_root/releases/.incoming.${USER}.$$"

    release_state="$(
        remote_tools_ssh_bash_args \
            "$remote_release_directory" "$bundle_digest" <<'REMOTE_CHECK'
set -Eeuo pipefail
release_directory="$1"
expected_manifest_digest="$2"

bundle_is_valid() {
    local requested_directory="$1"
    local requested_manifest_digest="$2"
    local actual_files
    local actual_manifest_digest
    local manifest_files

    [[ -d "$requested_directory" ]] || return 1
    actual_manifest_digest="$(
        sha256sum "$requested_directory/bundle.sha256" 2>/dev/null |
            awk '{ print $1; exit }'
    )" || return 1
    [[ "$actual_manifest_digest" == "$requested_manifest_digest" ]] || return 1
    (cd "$requested_directory" && sha256sum -c bundle.sha256 >/dev/null 2>&1) ||
        return 1
    actual_files="$(
        cd "$requested_directory" &&
            find . -type f ! -path './bundle.sha256' -printf '%P\n' |
            LC_ALL=C sort
    )"
    manifest_files="$(
        awk '
            NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 2 }
            { print $2 }
        ' "$requested_directory/bundle.sha256" 2>/dev/null | LC_ALL=C sort
    )" || return 1
    [[ "$actual_files" == "$manifest_files" ]]
}

if [[ ! -e "$release_directory" ]]; then
    printf 'missing\n'
elif [[ ! -d "$release_directory" ]]; then
    printf 'invalid\n'
elif bundle_is_valid "$release_directory" "$expected_manifest_digest"; then
    printf 'valid\n'
else
    printf 'invalid\n'
fi
REMOTE_CHECK
    )" || return 1

    case "$release_state" in
        valid)
            echo "VNC bundle already exists: $remote_release_directory"
            ;;
        invalid)
            echo "Error: remote VNC release failed its checksum check: $remote_release_directory" >&2
            return 1
            ;;
        missing)
            echo "Copying VNC bundle to $remote_release_directory..."
            remote_tools_ssh_bash_args \
                "$remote_vnc_root" "$remote_incoming_directory" <<'REMOTE_PREPARE'
set -Eeuo pipefail
vnc_root="$1"
incoming_directory="$2"
umask 007
mkdir -p "$vnc_root/releases" "$vnc_root/users"
chmod 2770 "$vnc_root" "$vnc_root/releases" 2>/dev/null || true
chmod 3770 "$vnc_root/users" 2>/dev/null || true
[[ ! -e "$incoming_directory" ]] || {
    printf 'Incoming VNC bundle path already exists: %s\n' "$incoming_directory" >&2
    exit 2
}
mkdir "$incoming_directory"
chmod 700 "$incoming_directory"
REMOTE_PREPARE
            if [ $? -ne 0 ]; then
                return 1
            fi

            if ! (
                set -o pipefail
                COPYFILE_DISABLE=1 \
                    tar --no-xattrs -C "$bundle_directory" -czf - . |
                    remote_tools_ssh_command /bin/bash -c '
set -Eeuo pipefail
incoming_directory="$1"
[[ -d "$incoming_directory" ]] || exit 2
tar -xzf - -C "$incoming_directory"
' remote-vnc-extract "$remote_incoming_directory"
            ); then
                remove_remote_vnc_incoming_directory \
                    "$remote_incoming_directory" >/dev/null 2>&1 || true
                echo "Error: could not copy the VNC bundle" >&2
                return 1
            fi

            if ! remote_tools_ssh_bash_args \
                "$remote_vnc_root" "$remote_incoming_directory" \
                "$remote_release_directory" "$bundle_digest" <<'REMOTE_INSTALL'
set -Eeuo pipefail
vnc_root="$1"
incoming_directory="$2"
release_directory="$3"
expected_manifest_digest="$4"

bundle_is_valid() {
    local requested_directory="$1"
    local requested_manifest_digest="$2"
    local actual_files
    local actual_manifest_digest
    local manifest_files

    [[ -d "$requested_directory" ]] || return 1
    actual_manifest_digest="$(
        sha256sum "$requested_directory/bundle.sha256" 2>/dev/null |
            awk '{ print $1; exit }'
    )" || return 1
    [[ "$actual_manifest_digest" == "$requested_manifest_digest" ]] || return 1
    (cd "$requested_directory" && sha256sum -c bundle.sha256 >/dev/null 2>&1) ||
        return 1
    actual_files="$(
        cd "$requested_directory" &&
            find . -type f ! -path './bundle.sha256' -printf '%P\n' |
            LC_ALL=C sort
    )"
    manifest_files="$(
        awk '
            NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 2 }
            { print $2 }
        ' "$requested_directory/bundle.sha256" 2>/dev/null | LC_ALL=C sort
    )" || return 1
    [[ "$actual_files" == "$manifest_files" ]]
}

[[ -d "$incoming_directory" ]] || {
    printf 'Incoming VNC bundle is missing: %s\n' "$incoming_directory" >&2
    exit 2
}
bundle_is_valid "$incoming_directory" "$expected_manifest_digest" || {
    printf 'Incoming VNC bundle failed validation: %s\n' \
        "$incoming_directory" >&2
    exit 2
}
find "$incoming_directory" -type d -exec chmod 0555 {} +
find "$incoming_directory" -type f -name '*.sh' -exec chmod 0555 {} +
find "$incoming_directory" -type f ! -name '*.sh' -exec chmod 0444 {} +

exec 9> "$vnc_root/.deploy.lock"
chmod 0660 "$vnc_root/.deploy.lock" 2>/dev/null || true
flock 9
if [[ -e "$release_directory" ]]; then
    if bundle_is_valid "$release_directory" "$expected_manifest_digest"; then
        chmod 0700 "$incoming_directory"
        find "$incoming_directory" -type d -exec chmod 0700 {} +
        rm -rf -- "$incoming_directory"
        exit 0
    fi
    printf 'Remote VNC release appeared but failed validation: %s\n' \
        "$release_directory" >&2
    exit 3
fi
mv "$incoming_directory" "$release_directory"
REMOTE_INSTALL
            then
                remove_remote_vnc_incoming_directory \
                    "$remote_incoming_directory" >/dev/null 2>&1 || true
                echo "Error: could not install the VNC bundle" >&2
                return 1
            fi
            ;;
        *)
            echo "Error: unexpected VNC release state: $release_state" >&2
            return 1
            ;;
    esac

    REMOTE_VNC_RELEASE_DIRECTORY="$remote_release_directory"
    export REMOTE_VNC_RELEASE_DIRECTORY
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
    local control_path

    remote_tools_require_context || return 1
    control_path="$(remote_tools_control_path)"

    if [ ! -d "$remote_tools_dir/dropbear" ]; then
        echo "Error: local dropbear directory not found at $remote_tools_dir/dropbear" >&2
        return 1
    fi

    echo "Copying local dropbear tree to $REMOTE_SHARED_ROOT/dropbear..."
    tar -C "$remote_tools_dir" -czf - dropbear | ssh -o ControlMaster=auto \
        -o ControlPath="$control_path" \
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
