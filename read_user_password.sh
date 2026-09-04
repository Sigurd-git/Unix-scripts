#!/usr/bin/env bash

user_password_script_directory="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
USER_PASSWORD_FILE="${USER_PASSWORD_FILE:-${user_password_script_directory}/user_password.txt}"
REMOTE_SHARED_ROOT_DEFAULT="/scratch/snormanh_lab/shared"
REMOTE_VNC_SSH_PORT_CREATED=false

if [ ! -f "$USER_PASSWORD_FILE" ]; then
    echo "Error: $USER_PASSWORD_FILE not found" >&2
    exit 1
fi

{
    IFS= read -r line1 || true
    IFS= read -r line2 || true
    IFS= read -r line3 || true
    IFS= read -r line4 || true
} < "$USER_PASSWORD_FILE"

if [[ "$line3" == REMOTE_SHARED_ROOT=* ]]; then
    line3="${line3#REMOTE_SHARED_ROOT=}"
fi
if [[ "$line4" == REMOTE_VNC_SSH_PORT=* ]]; then
    line4="${line4#REMOTE_VNC_SSH_PORT=}"
fi

initialize_remote_vnc_ssh_port() {
    local generated_port
    local temporary_config_file
    local user_checksum

    command -v cksum >/dev/null 2>&1 || {
        echo "Error: cksum is required to initialize the remote VNC SSH port" >&2
        return 1
    }
    command -v awk >/dev/null 2>&1 || {
        echo "Error: awk is required to initialize the remote VNC SSH port" >&2
        return 1
    }
    command -v mktemp >/dev/null 2>&1 || {
        echo "Error: mktemp is required to initialize the remote VNC SSH port" >&2
        return 1
    }
    [[ -w "$USER_PASSWORD_FILE" ]] || {
        echo "Error: $USER_PASSWORD_FILE is not writable; add a port on line 4" >&2
        return 1
    }

    user_checksum="$(printf '%s' "$line1" | cksum | awk '{ print $1; exit }')"
    [[ "$user_checksum" =~ ^[0-9]+$ ]] || {
        echo "Error: could not derive a remote VNC SSH port" >&2
        return 1
    }
    generated_port=$((44000 + user_checksum % 1000))
    temporary_config_file="$(mktemp "${USER_PASSWORD_FILE}.tmp.XXXXXX")" ||
        return 1
    if ! awk -v generated_port="$generated_port" '
        NR == 4 {
            print generated_port
            next
        }
        { print }
        END {
            for (line_number = NR + 1; line_number <= 3; line_number++) {
                print ""
            }
            if (NR < 4) {
                print generated_port
            }
        }
    ' "$USER_PASSWORD_FILE" > "$temporary_config_file"; then
        rm -f "$temporary_config_file"
        return 1
    fi
    if ! chmod 600 "$temporary_config_file"; then
        rm -f "$temporary_config_file"
        return 1
    fi
    if ! mv "$temporary_config_file" "$USER_PASSWORD_FILE"; then
        rm -f "$temporary_config_file"
        return 1
    fi
    line4="$generated_port"
    REMOTE_VNC_SSH_PORT_CREATED=true
}

if [[ "${READ_USER_PASSWORD_INITIALIZE_VNC_PORT:-false}" == "true" &&
      -z "$line4" ]]; then
    initialize_remote_vnc_ssh_port || exit 1
fi
if [[ "${READ_USER_PASSWORD_INITIALIZE_VNC_PORT:-false}" == "true" ]]; then
    if [[ ! "$line4" =~ ^[0-9]+$ ]] ||
       ((line4 < 44000 || line4 > 44999)); then
        echo "Error: line 4 of $USER_PASSWORD_FILE must be a port from 44000 to 44999" >&2
        exit 1
    fi
fi

# set environment variables
export USER="$line1"

# Check if password was read successfully, if not prompt for manual input
if [ -z "$line2" ] && [ -z "${PASSWORD:-}" ]; then
    echo "Password not found in file. Please enter password manually:"
    read -s -p "Password: " line2
    echo  # Add newline after password input
fi

export PASSWORD="$line2"
export REMOTE_SHARED_ROOT="${line3:-$REMOTE_SHARED_ROOT_DEFAULT}"
export REMOTE_VNC_SSH_PORT="$line4"
export REMOTE_VNC_SSH_PORT_CREATED

echo "USER: $USER"
echo "REMOTE_SHARED_ROOT: $REMOTE_SHARED_ROOT"
# echo "PASSWORD: $PASSWORD"
