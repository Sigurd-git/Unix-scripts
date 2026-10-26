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
    -o ConnectTimeout=15
    -o ConnectionAttempts=1
    -o ControlMaster=yes
    -o "ControlPath=${SSH_CONTROL_PATH}"
    -o ControlPersist=no
    -o ServerAliveInterval=60
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
    -fN
)

login_proxy_config="$(cluster_login_proxy_config "${CLUSTER}" "${REMOTE_USER}")" || exit 1
case "${login_proxy_config}" in
    proxyjump\ *)
        jump_hosts="${login_proxy_config#proxyjump }"
        jump_target="${jump_hosts##*,}"
        # -J with -F /dev/null would also hide the jump host's configuration.
        # Let the proxy SSH resolve its alias using the normal user config.
        login_proxy_command='/usr/bin/ssh -o ConnectTimeout=15 -o ConnectionAttempts=1 -o ClearAllForwardings=yes'
        if [[ "${jump_hosts}" == *,* ]]; then
            printf -v login_proxy_command '%s -J %q' \
                "${login_proxy_command}" "${jump_hosts%,*}"
        fi
        # ssh -G normalizes SSH URIs to [user@]host[:port]. Pass the user and
        # port separately, since a bare ssh destination does not accept :port.
        if [[ "${jump_target}" == *@* ]]; then
            printf -v login_proxy_command '%s -l %q' \
                "${login_proxy_command}" "${jump_target%@*}"
            jump_target="${jump_target##*@}"
        fi
        case "${jump_target}" in
            \[*\]) ;; # An IPv6 literal without a port.
            *:*)
                printf -v login_proxy_command '%s -p %q' \
                    "${login_proxy_command}" "${jump_target##*:}"
                jump_target="${jump_target%:*}"
                ;;
        esac
        jump_target="${jump_target#\[}"
        jump_target="${jump_target%\]}"
        printf -v login_proxy_command "%s -W '[%%h]:%%p' -- %q" \
            "${login_proxy_command}" "${jump_target}"
        ssh_arguments+=(-o "ProxyCommand=${login_proxy_command}")
        printf 'Using SSH jump host(s): %s\n' "${jump_hosts}"
        ;;
    proxycommand\ *)
        ssh_arguments+=(-o "ProxyCommand=${login_proxy_config#proxycommand }")
        printf 'Using ProxyCommand from SSH configuration.\n'
        ;;
    *)
        printf 'Connecting directly (connection timeout: 15 seconds).\n'
        ;;
esac
ssh_arguments+=("${SSH_LOGIN_TARGET}")

ssh_status=0
if [[ -n "${PASSWORD}" ]]; then
    # sshpass's controlling PTY can hang up the proxy when ssh -f forks.
    # Native askpass supplies the saved password without owning a terminal.
    REMOTE_SSH_PASSWORD="${PASSWORD}" \
    REMOTE_SSH_PASSWORD_TARGET="${SSH_LOGIN_TARGET}" \
    SSH_ASKPASS="${current_path}/ssh_login_askpass.sh" \
    SSH_ASKPASS_REQUIRE=force \
        /usr/bin/ssh -o NumberOfPasswordPrompts=1 "${ssh_arguments[@]}" || ssh_status=$?
else
    /usr/bin/ssh "${ssh_arguments[@]}" || ssh_status=$?
fi
if [[ "${ssh_status}" -ne 0 ]]; then
    printf 'Error: SSH connection to %s failed (status %s); see the SSH error above.\n' \
        "${CLUSTER}" "${ssh_status}" >&2
    exit "${ssh_status}"
fi

control_status="$(
    /usr/bin/ssh -F /dev/null -S "${SSH_CONTROL_PATH}" -O check \
        "${SSH_LOGIN_TARGET}" 2>&1 || true
)"
[[ "${control_status}" == *"Master running"* ]] || {
    echo "Error: SSH control master did not start at ${SSH_CONTROL_PATH}" >&2
    printf '%s\n' "${control_status}" >&2
    exit 1
}
sync_shared_ssh_aliases
echo "SSH session to ${CLUSTER} is ready."
