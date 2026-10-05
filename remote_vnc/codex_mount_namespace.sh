#!/usr/bin/env bash

set -Eeuo pipefail

[[ $# -gt 0 ]] || {
    printf 'Usage: codex_mount_namespace.sh COMMAND [ARG ...]\n' >&2
    exit 2
}

# A detached daemon must not retain Apptainer's fakeroot preload. The child
# user namespace can change mount propagation without affecting the VNC desktop.
unset LD_PRELOAD FAKEROOTKEY FAKED_MODE FAKEROOTDONTTRYCHOWN
exec unshare --user --map-root-user --mount /bin/bash -c '
    set -Eeuo pipefail
    mount --make-rprivate /
    exec "$@"
' bash "$@"
