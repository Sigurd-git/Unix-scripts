#!/usr/bin/env bash

# Run inside the job's service instance, including commands from container SSH.
set -Eeuo pipefail
umask 077

managed_ocx="${1:?OpenCodex executable is required}"
managed_codex="${2:?Codex executable is required}"
opencodex_log="${3:?OpenCodex log is required}"
shift 3
release_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    start)
        # ocx start runs in the foreground. Detach it inside the instance so
        # neither the caller's SSH session nor this command owns its lifetime.
        mkdir -p "${HOME}/.local/share/remote-vnc"
        exec 9> "${HOME}/.local/share/remote-vnc/ocx-start.lock"
        flock -w 120 9
        if ! "${managed_ocx}" ready --json >/dev/null 2>&1; then
            nohup "${managed_ocx}" "$@" </dev/null \
                >> "${opencodex_log}" 2>&1 9>&- &
        fi
        timeout 130 "${managed_ocx}" ready --wait --timeout 120
        ;;
    update)
        if [[ $# -eq 1 ]]; then
            # Use the same persistent installation and checks as a new job.
            exec "${release_directory}/update_ai_tools.sh" "${managed_codex}" ocx
        fi
        exec "${managed_ocx}" "$@"
        ;;
    *)
        exec "${managed_ocx}" "$@"
        ;;
esac
