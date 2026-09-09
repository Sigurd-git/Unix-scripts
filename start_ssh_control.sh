#!/usr/bin/env bash

current_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${current_path}/cluster_helpers.sh"

CLUSTER="bluehive3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--cluster)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "Error: $1 requires a cluster name" >&2
                exit 1
            fi
            CLUSTER="$2"
            shift 2
            ;;
        --cluster=*)
            CLUSTER="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-a|--cluster CLUSTER]"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Unexpected argument '$1'" >&2
            exit 1
            ;;
    esac
done
[[ $# -eq 0 ]] || {
    echo "Error: Unexpected positional arguments: $*" >&2
    exit 1
}

require_cluster "${CLUSTER}" || exit 1
HOSTNAME="$(cluster_hostname "${CLUSTER}")" || exit 1
source "${current_path}/read_user_password.sh" || exit 1

SSH_CONTROL_PATH="$(cluster_control_path "${CLUSTER}")" || exit 1
SSH_LOGIN_TARGET="${REMOTE_USER}@${HOSTNAME}"
REMOTE_TOOLS_CONTROL_PATH="${SSH_CONTROL_PATH}"
export CLUSTER HOSTNAME SSH_CONTROL_PATH SSH_LOGIN_TARGET
export REMOTE_TOOLS_CONTROL_PATH

sync_shared_ssh_aliases() {
    bash "${current_path}/sync_ssh_config.sh" -a "${CLUSTER}" ||
        printf 'Could not refresh standard SSH aliases; run sync_ssh_config.sh -a %s to retry.\n' \
            "${CLUSTER}" >&2
}

control_status="$(
    /usr/bin/ssh -F /dev/null -S "${SSH_CONTROL_PATH}" -O check \
        "${SSH_LOGIN_TARGET}" 2>&1 || true
)"
if [[ "${control_status}" == *"Master running"* ]]; then
    sync_shared_ssh_aliases
    echo "Reusing SSH session to ${CLUSTER}."
    return 0 2>/dev/null || exit 0
fi

if [[ -S "${SSH_CONTROL_PATH}" ]]; then
    unlink "${SSH_CONTROL_PATH}"
elif [[ -e "${SSH_CONTROL_PATH}" ]]; then
    echo "Error: SSH ControlPath exists but is not a socket: ${SSH_CONTROL_PATH}" >&2
    exit 1
fi

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

echo "Starting SSH session to ${CLUSTER}; complete password and Duo prompts if shown."
ssh_arguments=(
    -F /dev/null
    -o ControlMaster=yes
    -o "ControlPath=${SSH_CONTROL_PATH}"
    -o ControlPersist=no
    -o ServerAliveInterval=60
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
    -fN
    "${SSH_LOGIN_TARGET}"
)

sshpass_binary=""
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        [[ -x "${current_path}/sshpass_mac_arm64" ]] &&
            sshpass_binary="${current_path}/sshpass_mac_arm64"
        ;;
    Linux-x86_64)
        [[ -x "${current_path}/sshpass_linux_amd64" ]] &&
            sshpass_binary="${current_path}/sshpass_linux_amd64"
        ;;
esac

if [[ -n "${PASSWORD}" && -n "${sshpass_binary}" ]]; then
    SSHPASS="${PASSWORD}" "${sshpass_binary}" -e /usr/bin/ssh "${ssh_arguments[@]}"
else
    /usr/bin/ssh "${ssh_arguments[@]}"
fi

control_status="$(
    /usr/bin/ssh -F /dev/null -S "${SSH_CONTROL_PATH}" -O check \
        "${SSH_LOGIN_TARGET}" 2>&1 || true
)"
[[ "${control_status}" == *"Master running"* ]] || {
    echo "Error: SSH control master did not start at ${SSH_CONTROL_PATH}" >&2
    exit 1
}
sync_shared_ssh_aliases
