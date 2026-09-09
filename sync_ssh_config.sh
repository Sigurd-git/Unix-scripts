#!/usr/bin/env bash

# Export the explicit connection settings to ordinary OpenSSH clients. The
# launchers still use -F /dev/null, so these aliases are not a prerequisite.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cluster_helpers.sh"

ssh_config_state_value() {
    awk -F= -v requested_key="$2" '
        $1 == requested_key { sub(/^[^=]*=/, ""); print; exit }
    ' "$1"
}

ssh_config_quoted_path() {
    local path_value="$1"
    path_value="${path_value//\\/\\\\}"
    path_value="${path_value//\"/\\\"}"
    path_value="${path_value//%/%%}"
    printf '"%s"' "${path_value}"
}

sync_cluster_ssh_config() (
    set -Eeuo pipefail
    umask 077

    local cluster_name="$1"
    local remote_user_name="$2"
    local ssh_config_file="${3:-${HOME}/.ssh/config}"
    local vnc_state_file="${4:-${HOME}/.ssh/remote_vnc_${cluster_name}.env}"
    local login_hostname login_control_path login_shortcut
    local compute_node="" compute_port compute_control_path identity_file
    local known_hosts_file host_key_alias login_proxy_command state_value
    local temporary_config_file="" backup_file lock_acquired=false
    local symlink_target link_number attempt_number
    local block_begin="# BEGIN unix-scripts ${cluster_name}"
    local block_end="# END unix-scripts ${cluster_name}"

    require_cluster "${cluster_name}" || return 1
    [[ "${remote_user_name}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    login_hostname="$(cluster_hostname "${cluster_name}")"
    login_control_path="$(cluster_control_path "${cluster_name}")"
    case "${cluster_name}" in
        bluehive) login_shortcut=blh ;;
        bluehive3) login_shortcut=blh3 ;;
        bhward) login_shortcut=bhw ;;
    esac

    if [[ -s "${vnc_state_file}" ]] &&
       [[ "$(ssh_config_state_value "${vnc_state_file}" STATE_VERSION)" == 2 ]] &&
       [[ "$(ssh_config_state_value "${vnc_state_file}" REMOTE_USER)" == "${remote_user_name}" ]]; then
        compute_node="$(ssh_config_state_value "${vnc_state_file}" NODE)"
        compute_port="$(ssh_config_state_value "${vnc_state_file}" REMOTE_SSH_PORT)"
        compute_control_path="$(ssh_config_state_value "${vnc_state_file}" SSH_CONTROL_PATH)"
        identity_file="$(ssh_config_state_value "${vnc_state_file}" IDENTITY_FILE)"
        known_hosts_file="$(ssh_config_state_value "${vnc_state_file}" KNOWN_HOSTS_FILE)"
        host_key_alias="$(ssh_config_state_value "${vnc_state_file}" HOST_KEY_ALIAS)"
        [[ "${compute_node}" =~ ^[A-Za-z0-9._-]+$ &&
           "${compute_port}" =~ ^[0-9]+$ &&
           "${host_key_alias}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        ((compute_port >= 1 && compute_port <= 65535)) || return 1
        for state_value in "${compute_control_path}" "${identity_file}" "${known_hosts_file}"; do
            [[ "${state_value}" == /* && "${state_value}" != *$'\n'* &&
               "${state_value}" != *$'\r'* ]] || return 1
        done
        printf -v login_proxy_command \
            '/usr/bin/ssh -F /dev/null -S %q -o BatchMode=yes -o ConnectTimeout=15 -W %%h:%%p %q' \
            "${login_control_path}" "${remote_user_name}@${login_hostname}"
    fi

    # Keep dotfile-manager symlinks intact when replacing the configuration.
    for ((link_number = 0; link_number < 40; link_number++)); do
        [[ -L "${ssh_config_file}" ]] || break
        symlink_target="$(readlink "${ssh_config_file}")"
        if [[ "${symlink_target}" == /* ]]; then
            ssh_config_file="${symlink_target}"
        else
            ssh_config_file="$(dirname "${ssh_config_file}")/${symlink_target}"
        fi
    done
    [[ ! -L "${ssh_config_file}" ]] || return 1
    mkdir -p "$(dirname "${ssh_config_file}")"

    # Login and VNC startup can export aliases at the same time.
    for ((attempt_number = 0; attempt_number < 50; attempt_number++)); do
        if mkdir "${ssh_config_file}.unix-scripts-lock" 2>/dev/null; then
            lock_acquired=true
            break
        fi
        sleep 0.1
    done
    [[ "${lock_acquired}" == true ]] || {
        printf 'SSH configuration is busy: %s\n' "${ssh_config_file}" >&2
        return 1
    }
    trap '[[ -z "${temporary_config_file}" ]] || rm -f "${temporary_config_file}";
          rmdir "${ssh_config_file}.unix-scripts-lock"' EXIT
    temporary_config_file="$(mktemp "${ssh_config_file}.unix-scripts.XXXXXX")"

    {
        printf '%s\n' "${block_begin}"
        printf '# Updated by sync_ssh_config.sh; shares the launchers\047 SSH connections.\n'
        printf 'Host %s %s %s\n' "${cluster_name}" "${login_hostname}" "${login_shortcut}"
        printf '    HostName %s\n    User %s\n    Port 22\n' \
            "${login_hostname}" "${remote_user_name}"
        printf '    ControlMaster auto\n    ControlPersist no\n    ControlPath %s\n' \
            "$(ssh_config_quoted_path "${login_control_path}")"
        printf '    ProxyCommand none\n'
        if [[ -n "${compute_node}" ]]; then
            printf '\nHost %s %s\n' "$(cluster_compute_host "${cluster_name}")" \
                "$(cluster_shortcut "${cluster_name}")"
            printf '    HostName %s\n    User %s\n    Port %s\n' \
                "${compute_node}" "${remote_user_name}" "${compute_port}"
            printf '    ControlMaster auto\n    ControlPersist no\n    ControlPath %s\n' \
                "$(ssh_config_quoted_path "${compute_control_path}")"
            printf '    IdentityFile %s\n    IdentitiesOnly yes\n' \
                "$(ssh_config_quoted_path "${identity_file}")"
            printf '    UserKnownHostsFile %s\n    HostKeyAlias %s\n' \
                "$(ssh_config_quoted_path "${known_hosts_file}")" "${host_key_alias}"
            printf '    StrictHostKeyChecking yes\n    ProxyCommand %s\n' "${login_proxy_command}"
        fi
        # Restore global scope for any original options preceding a Host block.
        printf '\nHost *\n%s\n' "${block_end}"
        if [[ -f "${ssh_config_file}" ]]; then
            awk -v block_begin="${block_begin}" -v block_end="${block_end}" '
                $0 == block_begin { in_managed_block=1; next }
                $0 == block_end { in_managed_block=0; next }
                !in_managed_block { print }
                END { if (in_managed_block) exit 1 }
            ' "${ssh_config_file}"
        fi
    } > "${temporary_config_file}"

    /usr/bin/ssh -G -T -F "${temporary_config_file}" "${cluster_name}" >/dev/null
    if [[ -n "${compute_node}" ]]; then
        /usr/bin/ssh -G -T -F "${temporary_config_file}" \
            "$(cluster_shortcut "${cluster_name}")" >/dev/null
    fi
    if [[ -f "${ssh_config_file}" ]] && cmp -s "${temporary_config_file}" "${ssh_config_file}"; then
        return 0
    fi
    if [[ -f "${ssh_config_file}" ]]; then
        backup_file="$(mktemp "${ssh_config_file}.unix-scripts-backup.XXXXXX")"
        cp -p "${ssh_config_file}" "${backup_file}"
        chmod 600 "${backup_file}"
    fi
    chmod 600 "${temporary_config_file}"
    mv "${temporary_config_file}" "${ssh_config_file}"
    temporary_config_file=""
    printf 'Updated shared SSH aliases in %s\n' "${ssh_config_file}"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    cluster_name=bluehive3
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--cluster) cluster_name="${2:?cluster name is required}"; shift 2 ;;
            -h|--help)
                printf 'Usage: sync_ssh_config.sh [-a|--cluster CLUSTER]\n'
                printf 'Refresh standard SSH aliases from the profile and saved VNC connection.\n'
                exit 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    REMOTE_CONFIG_QUIET=true
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/read_user_password.sh"
    sync_cluster_ssh_config "${cluster_name}" "${REMOTE_USER}"
fi
