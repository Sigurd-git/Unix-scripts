#!/usr/bin/env bash

# Shared, sourceable configuration loader. New installations use a named config
# under ~/.config; the historical four-line user_password.txt remains readable.

remote_config_script_directory="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
remote_config_legacy_file="${remote_config_script_directory}/user_password.txt"
remote_config_default_file="${XDG_CONFIG_HOME:-${HOME}/.config}/unix-scripts/config"
REMOTE_SHARED_ROOT_DEFAULT="/scratch/snormanh_lab/shared"
REMOTE_VNC_SSH_PORT_CREATED=false
REMOTE_CONFIG_CREATED=false

if [[ -n "${REMOTE_CONFIG_FILE:-}" ]]; then
    remote_config_file="${REMOTE_CONFIG_FILE}"
elif [[ -n "${USER_PASSWORD_FILE:-}" ]]; then
    remote_config_file="${USER_PASSWORD_FILE}"
elif [[ -f "${remote_config_legacy_file}" ]]; then
    remote_config_file="${remote_config_legacy_file}"
else
    remote_config_file="${remote_config_default_file}"
fi
REMOTE_CONFIG_FILE="${remote_config_file}"
USER_PASSWORD_FILE="${remote_config_file}"
export REMOTE_CONFIG_FILE USER_PASSWORD_FILE

remote_config_fail() {
    printf 'Error: %s\n' "$*" >&2
    return 1
}

remote_config_has_terminal() {
    [[ "${REMOTE_CONFIG_INTERACTIVE:-false}" == "true" || -t 0 ]]
}

remote_config_prompt() {
    local prompt_text="$1"
    local default_value="${2:-}"
    local entered_value

    if [[ -n "${default_value}" ]]; then
        printf '%s [%s]: ' "${prompt_text}" "${default_value}" >&2
    else
        printf '%s: ' "${prompt_text}" >&2
    fi
    IFS= read -r entered_value || return 1
    printf '%s' "${entered_value:-${default_value}}"
}

remote_config_prompt_secret() {
    local entered_value

    printf 'BlueHive password (optional; press Enter to let ssh ask): ' >&2
    IFS= read -r -s entered_value || return 1
    printf '\n' >&2
    printf '%s' "${entered_value}"
}

remote_config_confirm() {
    local prompt_text="$1"
    local default_answer="$2"
    local answer
    local prompt_suffix='[y/N]'

    [[ "${default_answer}" == "yes" ]] && prompt_suffix='[Y/n]'
    printf '%s %s ' "${prompt_text}" "${prompt_suffix}" >&2
    IFS= read -r answer || return 1
    case "${answer}" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        n|N|no|NO|No)
            return 1
            ;;
        '')
            [[ "${default_answer}" == "yes" ]]
            ;;
        *)
            printf 'Please answer y or n.\n' >&2
            remote_config_confirm "${prompt_text}" "${default_answer}"
            ;;
    esac
}

remote_config_derive_port() {
    local remote_user_name="$1"
    local user_checksum

    command -v cksum >/dev/null 2>&1 ||
        remote_config_fail "cksum is required to derive the remote VNC SSH port" ||
        return 1
    command -v awk >/dev/null 2>&1 ||
        remote_config_fail "awk is required to derive the remote VNC SSH port" ||
        return 1
    user_checksum="$(printf '%s' "${remote_user_name}" | cksum | awk '{ print $1; exit }')"
    [[ "${user_checksum}" =~ ^[0-9]+$ ]] ||
        remote_config_fail "could not derive a remote VNC SSH port" ||
        return 1
    printf '%s\n' "$((44000 + user_checksum % 1000))"
}

remote_config_read_file() {
    local config_line
    local line1=""
    local line2=""
    local line3=""
    local line4=""

    remote_config_user=""
    remote_config_password=""
    remote_config_root=""
    remote_config_port=""
    remote_config_format="key_value"

    IFS= read -r line1 || true
    IFS= read -r line2 || true
    IFS= read -r line3 || true
    IFS= read -r line4 || true

    case "${line1}" in
        REMOTE_USER=*|USER=*)
            while IFS= read -r config_line || [[ -n "${config_line}" ]]; do
                case "${config_line}" in
                    REMOTE_USER=*) remote_config_user="${config_line#REMOTE_USER=}" ;;
                    USER=*) remote_config_user="${config_line#USER=}" ;;
                    PASSWORD=*) remote_config_password="${config_line#PASSWORD=}" ;;
                    REMOTE_SHARED_ROOT=*) remote_config_root="${config_line#REMOTE_SHARED_ROOT=}" ;;
                    REMOTE_VNC_SSH_PORT=*) remote_config_port="${config_line#REMOTE_VNC_SSH_PORT=}" ;;
                    ''|'#'*) ;;
                esac
            done < "${remote_config_file}"
            ;;
        *)
            remote_config_format="legacy"
            remote_config_user="${line1}"
            remote_config_password="${line2}"
            remote_config_root="${line3#REMOTE_SHARED_ROOT=}"
            remote_config_port="${line4#REMOTE_VNC_SSH_PORT=}"
            ;;
    esac
}

remote_config_write_file() {
    local password_to_save="$1"
    local config_directory
    local temporary_config_file

    config_directory="$(dirname "${remote_config_file}")"
    mkdir -p "${config_directory}" || return 1
    if [[ "${remote_config_file}" == "${remote_config_default_file}" ]]; then
        chmod 700 "${config_directory}" 2>/dev/null || true
    fi
    temporary_config_file="$(mktemp "${config_directory}/.config.XXXXXX")" ||
        return 1

    if [[ "${remote_config_format}" == "legacy" ]]; then
        printf '%s\n%s\n%s\n%s\n' \
            "${remote_user_name}" "${password_to_save}" \
            "${remote_shared_root}" "${remote_vnc_ssh_port}" \
            > "${temporary_config_file}"
    else
        printf 'REMOTE_USER=%s\nPASSWORD=%s\nREMOTE_SHARED_ROOT=%s\nREMOTE_VNC_SSH_PORT=%s\n' \
            "${remote_user_name}" "${password_to_save}" \
            "${remote_shared_root}" "${remote_vnc_ssh_port}" \
            > "${temporary_config_file}"
    fi
    chmod 600 "${temporary_config_file}" || {
        rm -f "${temporary_config_file}"
        return 1
    }
    mv "${temporary_config_file}" "${remote_config_file}" || {
        rm -f "${temporary_config_file}"
        return 1
    }
}

remote_config_load() {
    local config_file_exists=false
    local save_configuration=false
    local save_password=false
    local password_to_save=""
    local default_remote_user
    local default_remote_root

    if [[ -f "${remote_config_file}" ]]; then
        config_file_exists=true
        remote_config_read_file < "${remote_config_file}"
        chmod 600 "${remote_config_file}" 2>/dev/null || true
    else
        remote_config_user=""
        remote_config_password=""
        remote_config_root=""
        remote_config_port=""
        remote_config_format="key_value"
    fi

    remote_user_name="${REMOTE_USER:-${remote_config_user}}"
    remote_password="${PASSWORD:-${remote_config_password}}"
    remote_shared_root="${REMOTE_SHARED_ROOT:-${remote_config_root}}"
    remote_vnc_ssh_port="${REMOTE_VNC_SSH_PORT:-${remote_config_port}}"

    if [[ -z "${remote_user_name}" ]]; then
        remote_config_has_terminal || {
            remote_config_fail \
                "no remote profile exists; run interactively once or set REMOTE_USER" ||
                return 1
        }
        default_remote_user="$(id -un)"
        printf 'First-time Unix-scripts setup\n' >&2
        remote_user_name="$(
            remote_config_prompt "BlueHive username" "${default_remote_user}"
        )" || return 1
        [[ "${remote_user_name}" =~ ^[A-Za-z0-9._-]+$ ]] || {
            remote_config_fail "invalid remote username: ${remote_user_name}" ||
                return 1
        }
        default_remote_root="/scratch/${remote_user_name}"
        remote_shared_root="$(
            remote_config_prompt "Remote shared root" "${default_remote_root}"
        )" || return 1
        remote_password="$(remote_config_prompt_secret)" || return 1
        remote_vnc_ssh_port="$(remote_config_derive_port "${remote_user_name}")" ||
            return 1

        if remote_config_confirm \
            "Save username, root, and fixed VNC port to ${remote_config_file}?" yes; then
            save_configuration=true
            if [[ -n "${remote_password}" ]] && remote_config_confirm \
                "Also save the password as plaintext in this mode-0600 file?" no; then
                save_password=true
            fi
        fi
    fi

    [[ "${remote_user_name}" =~ ^[A-Za-z0-9._-]+$ ]] || {
        remote_config_fail "invalid remote username: ${remote_user_name}" ||
            return 1
    }

    if [[ -z "${remote_shared_root}" ]]; then
        if [[ "${config_file_exists}" == "true" ]]; then
            remote_shared_root="${REMOTE_SHARED_ROOT_DEFAULT}"
        else
            remote_shared_root="/scratch/${remote_user_name}"
        fi
    fi
    [[ "${remote_shared_root}" == /* ]] || {
        remote_config_fail "REMOTE_SHARED_ROOT must be an absolute path" || return 1
    }

    if [[ -z "${remote_vnc_ssh_port}" ]]; then
        remote_vnc_ssh_port="$(remote_config_derive_port "${remote_user_name}")" ||
            return 1
        if [[ "${config_file_exists}" == "true" &&
              "${READ_USER_PASSWORD_INITIALIZE_VNC_PORT:-false}" == "true" ]]; then
            save_configuration=true
            REMOTE_VNC_SSH_PORT_CREATED=true
        fi
    fi
    [[ "${remote_vnc_ssh_port}" =~ ^[0-9]+$ ]] &&
        ((remote_vnc_ssh_port >= 44000 && remote_vnc_ssh_port <= 44999)) || {
            remote_config_fail \
                "REMOTE_VNC_SSH_PORT must be between 44000 and 44999" ||
                return 1
        }

    if [[ "${save_configuration}" == "true" ]]; then
        [[ "${save_password}" == "true" ]] &&
            password_to_save="${remote_password}"
        if [[ "${config_file_exists}" == "true" &&
              -n "${remote_config_password}" ]]; then
            password_to_save="${remote_config_password}"
        fi
        remote_config_write_file "${password_to_save}" || {
            remote_config_fail "could not save ${remote_config_file}" || return 1
        }
        REMOTE_CONFIG_CREATED=true
    fi

    REMOTE_USER="${remote_user_name}"
    PASSWORD="${remote_password}"
    REMOTE_SHARED_ROOT="${remote_shared_root}"
    REMOTE_VNC_SSH_PORT="${remote_vnc_ssh_port}"

    # USER remains available for the older scripts and remote heredocs.
    USER="${REMOTE_USER}"
    export USER REMOTE_USER PASSWORD REMOTE_SHARED_ROOT REMOTE_VNC_SSH_PORT
    export REMOTE_VNC_SSH_PORT_CREATED REMOTE_CONFIG_CREATED

    if [[ "${REMOTE_CONFIG_QUIET:-false}" != "true" ]]; then
        printf 'REMOTE_USER: %s\n' "${REMOTE_USER}"
        printf 'REMOTE_SHARED_ROOT: %s\n' "${REMOTE_SHARED_ROOT}"
        if [[ "${REMOTE_CONFIG_CREATED}" == "true" ]]; then
            printf 'Saved remote profile: %s\n' "${remote_config_file}"
        fi
    fi
}

remote_config_load || {
    return 1 2>/dev/null || exit 1
}
