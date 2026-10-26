#!/usr/bin/env bash

# OpenSSH reads stdout through a private pipe. Never write the saved password
# to a file, terminal, or a prompt belonging to another host or a private key.
prompt_text="${1:-}"
if [[ "${SSH_ASKPASS_PROMPT:-}" == none ]]; then
    printf '%s\n' "${prompt_text}" >&2
    exit 0
fi
if [[ -n "${REMOTE_SSH_PASSWORD_TARGET:-}" &&
      -n "${REMOTE_SSH_PASSWORD:-}" &&
      "${prompt_text}" == "${REMOTE_SSH_PASSWORD_TARGET}'s password:"* ]]; then
    printf '%s\n' "${REMOTE_SSH_PASSWORD}"
    exit 0
fi

# Keep jump-host passwords, key passphrases, and additional Duo challenges
# interactive. Only the destination's ordinary password uses the saved value.
if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    printf 'SSH needs interactive input; rerun in a terminal. Prompt: %s\n' \
        "${prompt_text}" >&2
    exit 1
fi
printf '%s ' "${prompt_text}" >&3
prompt_status=0
IFS= read -r -s prompt_response <&3 || prompt_status=$?
printf '\n' >&3
[[ "${prompt_status}" -eq 0 ]] || exit "${prompt_status}"
if [[ "${SSH_ASKPASS_PROMPT:-}" == confirm ]]; then
    case "${prompt_response}" in
        y|Y|yes|YES|Yes) exit 0 ;;
        *) exit 1 ;;
    esac
fi
printf '%s\n' "${prompt_response}"
