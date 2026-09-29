#!/usr/bin/env bash

# Exercise listener ownership when an ordinary SSH client takes the shared
# ControlPath while the VNC LaunchAgent keeps its own forwarding alive.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT

awk '/^local_listener_process_ids\(\)/ {copy=1}
     copy && /^read_local_rfb_banner\(\)/ {exit}
     copy {print}' "${repository_directory}/remote_vnc.sh" \
    > "${fixture_directory}/listeners.sh"
source "${fixture_directory}/listeners.sh"

launch_agent_domain=gui/1
launch_agent_label=fixture-vnc
ssh_master_process_id=111
launchctl() {
    printf '    pid = 222\n'
}
lsof() {
    case "$*" in
        *:15941*) printf '222\n' ;;
        *:15942*) printf '111\n' ;;
        *:15943*) printf '333\n' ;;
    esac
}

listener_uses_managed_ssh 15941
listener_uses_managed_ssh 15942
if listener_uses_managed_ssh 15943; then
    printf 'Unrelated listener was accepted as a managed tunnel.\n' >&2
    exit 1
fi
ssh_master_process_id=333
listener_uses_managed_ssh 15941
if listener_uses_managed_ssh 15942; then
    printf 'Old SSH master listener was accepted after takeover.\n' >&2
    exit 1
fi
printf 'PASS: VNC forwarding owned by the LaunchAgent survives SSH ControlPath takeover\n'
