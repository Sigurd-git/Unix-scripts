#!/usr/bin/env bash

set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
configuration_loader="${repository_directory}/read_user_password.sh"

file_mode() {
    if stat -f '%Lp' "$1" >/dev/null 2>&1; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

key_value_config="${fixture_directory}/key-value-config"
printf '%s\n' \
    'REMOTE_USER=test_user' \
    'PASSWORD=' \
    'REMOTE_SHARED_ROOT=/scratch/test_user' \
    'REMOTE_VNC_SSH_PORT=44555' > "${key_value_config}"
chmod 644 "${key_value_config}"

env REMOTE_CONFIG_FILE="${key_value_config}" REMOTE_CONFIG_QUIET=true \
    bash -c '
        source "$1"
        [[ "$REMOTE_USER" == test_user ]]
        [[ "$USER" == test_user ]]
        [[ "$REMOTE_SHARED_ROOT" == /scratch/test_user ]]
        [[ "$REMOTE_VNC_SSH_PORT" == 44555 ]]
        [[ -z "$PASSWORD" ]]
    ' _ "${configuration_loader}"
[[ "$(file_mode "${key_value_config}")" == "600" ]]
printf 'PASS: key-value profile loads without exposing a password\n'

legacy_config="${fixture_directory}/legacy-config"
printf 'legacy_user\nlegacy_password\n\n' > "${legacy_config}"
env REMOTE_CONFIG_FILE="${legacy_config}" REMOTE_CONFIG_QUIET=true \
    READ_USER_PASSWORD_INITIALIZE_VNC_PORT=true \
    bash -c '
        source "$1"
        [[ "$REMOTE_USER" == legacy_user ]]
        [[ "$REMOTE_SHARED_ROOT" == /scratch/snormanh_lab/shared ]]
        [[ "$REMOTE_VNC_SSH_PORT" -ge 44000 ]]
        [[ "$REMOTE_VNC_SSH_PORT" -le 44999 ]]
        [[ "$REMOTE_VNC_SSH_PORT_CREATED" == true ]]
    ' _ "${configuration_loader}"
[[ "$(awk 'NR == 4 { print; exit }' "${legacy_config}")" =~ ^44[0-9]{3}$ ]]
[[ "$(file_mode "${legacy_config}")" == "600" ]]
printf 'PASS: legacy profile remains compatible and gains a stable port\n'

wizard_home="${fixture_directory}/wizard-home"
wizard_config="${wizard_home}/config"
mkdir -p "${wizard_home}"
printf 'new_user\n\nsession-password\n\n\n' |
    env HOME="${wizard_home}" REMOTE_CONFIG_FILE="${wizard_config}" \
        REMOTE_CONFIG_INTERACTIVE=true REMOTE_CONFIG_QUIET=true \
        bash -c '
            source "$1"
            [[ "$REMOTE_USER" == new_user ]]
            [[ "$REMOTE_SHARED_ROOT" == /scratch/new_user ]]
            [[ "$PASSWORD" == session-password ]]
        ' _ "${configuration_loader}"
grep -qx 'REMOTE_USER=new_user' "${wizard_config}"
grep -qx 'PASSWORD=' "${wizard_config}"
grep -qx 'REMOTE_SHARED_ROOT=/scratch/new_user' "${wizard_config}"
grep -Eq '^REMOTE_VNC_SSH_PORT=44[0-9]{3}$' "${wizard_config}"
[[ "$(file_mode "${wizard_config}")" == "600" ]]
printf 'PASS: first-run wizard saves the profile and omits the password by default\n'

if env HOME="${fixture_directory}/empty-home" \
    REMOTE_CONFIG_FILE="${fixture_directory}/missing-config" \
    REMOTE_CONFIG_QUIET=true bash -c 'source "$1"' \
    _ "${configuration_loader}" >"${fixture_directory}/stdout" \
    2>"${fixture_directory}/stderr"; then
    printf 'Expected missing noninteractive configuration to fail\n' >&2
    exit 1
fi
grep -q 'run interactively once or set REMOTE_USER' "${fixture_directory}/stderr"
printf 'PASS: noninteractive use gives an actionable configuration error\n'
