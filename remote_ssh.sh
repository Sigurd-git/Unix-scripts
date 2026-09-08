#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_directory}/cluster_helpers.sh"

cluster_name="bluehive3"
service_name="vnc"

print_usage() {
    cat <<'EOF'
Usage: remote_ssh.sh [options] [--] [remote-command [argument ...]]

Connect through the managed login ControlMaster without using ~/.ssh/config.

Options:
  -a, --cluster CLUSTER   Cluster name (default: bluehive3)
  -s, --service SERVICE   vnc or sshd (default: vnc)
  -h, --help              Show this help
EOF
}

fail() {
    printf '[remote-ssh] Error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--cluster)
            [[ -n "${2:-}" && "$2" != -* ]] ||
                fail "$1 requires a cluster name"
            cluster_name="$2"
            shift 2
            ;;
        --cluster=*)
            cluster_name="${1#*=}"
            shift
            ;;
        -s|--service)
            [[ -n "${2:-}" && "$2" != -* ]] ||
                fail "$1 requires vnc or sshd"
            service_name="$2"
            shift 2
            ;;
        --service=*)
            service_name="${1#*=}"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

require_cluster "${cluster_name}" || exit 1
case "${service_name}" in
    vnc|sshd) ;;
    *) fail "--service must be vnc or sshd" ;;
esac

read_state_value() {
    local state_file="$1"
    local requested_key="$2"

    awk -F= -v requested_key="${requested_key}" '
        $1 == requested_key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "${state_file}"
}

if [[ "${service_name}" == "vnc" ]]; then
    state_file="${HOME}/.ssh/remote_vnc_${cluster_name}.env"
else
    state_file="${XDG_STATE_HOME:-${HOME}/.local/state}/unix-scripts/remote_sshd_${cluster_name}.env"
fi
[[ -s "${state_file}" ]] ||
    fail "connection state is missing; run remote_${service_name}.sh first: ${state_file}"

state_remote_user="$(read_state_value "${state_file}" REMOTE_USER)"
compute_node="$(read_state_value "${state_file}" NODE)"
compute_port="$(read_state_value "${state_file}" PORT)"
if [[ "${service_name}" == "vnc" ]]; then
    compute_port="$(read_state_value "${state_file}" REMOTE_SSH_PORT)"
fi

[[ "${state_remote_user}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "invalid REMOTE_USER in ${state_file}"
[[ "${compute_node}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "invalid NODE in ${state_file}"
[[ "${compute_port}" =~ ^[0-9]+$ ]] &&
    ((compute_port >= 1 && compute_port <= 65535)) ||
    fail "invalid SSH port in ${state_file}"

REMOTE_CONFIG_QUIET=true
export REMOTE_CONFIG_QUIET
source "${script_directory}/read_user_password.sh"
[[ "${REMOTE_USER}" == "${state_remote_user}" ]] ||
    fail "saved connection belongs to ${state_remote_user}, current profile uses ${REMOTE_USER}"

"${script_directory}/start_ssh_control.sh" -a "${cluster_name}"

login_host="$(cluster_hostname "${cluster_name}")" || exit 1
login_control_path="$(cluster_control_path "${cluster_name}")" || exit 1
login_ssh_target="${REMOTE_USER}@${login_host}"
printf -v login_proxy_command \
    '/usr/bin/ssh -F /dev/null -S %q -o BatchMode=yes -o ConnectTimeout=15 -W %%h:%%p %q' \
    "${login_control_path}" "${login_ssh_target}"

ssh_arguments=(
    -F /dev/null
    -p "${compute_port}"
    -o ConnectTimeout=15
    -o "ProxyCommand=${login_proxy_command}"
)

if [[ "${service_name}" == "vnc" ]]; then
    state_version="$(read_state_value "${state_file}" STATE_VERSION)"
    [[ "${state_version}" == "2" ]] ||
        fail "connection state is from an older release; rerun remote_vnc.sh"
    identity_file="$(read_state_value "${state_file}" IDENTITY_FILE)"
    known_hosts_file="$(read_state_value "${state_file}" KNOWN_HOSTS_FILE)"
    host_key_alias="$(read_state_value "${state_file}" HOST_KEY_ALIAS)"
    compute_control_path="$(read_state_value "${state_file}" SSH_CONTROL_PATH)"
    [[ "${identity_file}" == /* && -r "${identity_file}" ]] ||
        fail "VNC identity is unavailable: ${identity_file:-unset}"
    [[ "${known_hosts_file}" == /* && -r "${known_hosts_file}" ]] ||
        fail "VNC known-hosts file is unavailable: ${known_hosts_file:-unset}"
    [[ "${compute_control_path}" == /* ]] ||
        fail "invalid VNC ControlPath in ${state_file}"
    [[ "${host_key_alias}" =~ ^[A-Za-z0-9._-]+$ ]] ||
        fail "invalid VNC host-key alias in ${state_file}"
    ssh_arguments+=(
        -o BatchMode=yes
        -o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=${known_hosts_file}"
        -o "HostKeyAlias=${host_key_alias}"
        -o "IdentityFile=${identity_file}"
        -o IdentitiesOnly=yes
        -o ControlMaster=auto
        -o "ControlPath=${compute_control_path}"
        -o ControlPersist=no
    )
else
    known_hosts_directory="${XDG_STATE_HOME:-${HOME}/.local/state}/unix-scripts"
    known_hosts_file="${known_hosts_directory}/known_hosts_remote_sshd_${cluster_name}"
    mkdir -p "${known_hosts_directory}"
    chmod 700 "${known_hosts_directory}"
    ssh_arguments+=(
        -o StrictHostKeyChecking=accept-new
        -o "UserKnownHostsFile=${known_hosts_file}"
        -o "HostKeyAlias=remote-sshd-${cluster_name}"
    )
fi

exec /usr/bin/ssh "${ssh_arguments[@]}" \
    "${REMOTE_USER}@${compute_node}" "$@"
