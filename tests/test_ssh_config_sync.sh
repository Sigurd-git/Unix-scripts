#!/usr/bin/env bash

set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ssh_config_synchronizer="${repository_directory}/sync_ssh_config.sh"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT

ssh_binary="$(command -v ssh)"
[[ -n "${ssh_binary}" ]] || {
    printf 'OpenSSH client is required for this test\n' >&2
    exit 1
}

ssh_config_value() {
    local ssh_config_file="$1"
    local host_alias="$2"
    local option_name="$3"

    "${ssh_binary}" -G -F "${ssh_config_file}" "${host_alias}" 2>/dev/null |
        awk -v option_name="${option_name}" '
            $1 == option_name {
                sub(/^[^[:space:]]+[[:space:]]+/, "")
                print
                exit
            }
        '
}

assert_ssh_config_value() {
    local ssh_config_file="$1"
    local host_alias="$2"
    local option_name="$3"
    local expected_value="$4"
    local actual_value

    actual_value="$(ssh_config_value \
        "${ssh_config_file}" "${host_alias}" "${option_name}")"
    [[ "${actual_value}" == "${expected_value}" ]] || {
        printf 'Expected %s for %s to be %s, got %s\n' \
            "${option_name}" "${host_alias}" "${expected_value}" \
            "${actual_value}" >&2
        exit 1
    }
}

write_vnc_state() {
    local state_file="$1"
    local remote_user="$2"
    local compute_node="$3"
    local remote_ssh_port="$4"
    local compute_control_path="$5"
    local identity_file="$6"
    local known_hosts_file="$7"
    local host_key_alias="$8"

    {
        printf 'STATE_VERSION=2\n'
        printf 'CLUSTER=bluehive3\n'
        printf 'REMOTE_USER=%s\n' "${remote_user}"
        printf 'NODE=%s\n' "${compute_node}"
        printf 'REMOTE_SSH_PORT=%s\n' "${remote_ssh_port}"
        printf 'SSH_CONTROL_PATH=%s\n' "${compute_control_path}"
        printf 'IDENTITY_FILE=%s\n' "${identity_file}"
        printf 'KNOWN_HOSTS_FILE=%s\n' "${known_hosts_file}"
        printf 'HOST_KEY_ALIAS=%s\n' "${host_key_alias}"
    } > "${state_file}"
}

[[ -f "${ssh_config_synchronizer}" ]] || {
    printf 'Missing synchronizer: %s\n' "${ssh_config_synchronizer}" >&2
    exit 1
}

source_output="$(bash -c '
    set -Eeuo pipefail
    source "$1"
    declare -F sync_cluster_ssh_config >/dev/null
' _ "${ssh_config_synchronizer}")"
[[ -z "${source_output}" ]]
printf 'PASS: sourcing the synchronizer only defines its interface\n'

# shellcheck source=../sync_ssh_config.sh
source "${ssh_config_synchronizer}"

first_run_directory="${fixture_directory}/first-run"
first_run_config="${first_run_directory}/config"
first_run_state="${first_run_directory}/missing-state.env"
mkdir -p "${first_run_directory}"
sync_cluster_ssh_config \
    bluehive3 test_user "${first_run_config}" "${first_run_state}"

[[ -s "${first_run_config}" ]]
assert_ssh_config_value \
    "${first_run_config}" bluehive3 hostname bluehive3.circ.rochester.edu
assert_ssh_config_value "${first_run_config}" bluehive3 user test_user
assert_ssh_config_value "${first_run_config}" blh3 user test_user
assert_ssh_config_value "${first_run_config}" bluehive3 controlmaster auto
expected_login_control_path="/tmp/unix-scripts-login-$(id -u)-bluehive3.sock"
assert_ssh_config_value \
    "${first_run_config}" bluehive3 controlpath \
    "${expected_login_control_path}"
if awk '
    $1 == "Host" {
        for (field_index = 2; field_index <= NF; field_index++) {
            if ($field_index == "bluehive_compute3" || $field_index == "blhc3") {
                found_compute_mapping = 1
            }
        }
    }
    END { exit found_compute_mapping ? 0 : 1 }
' "${first_run_config}"; then
    printf 'Compute aliases were generated without a valid VNC state\n' >&2
    exit 1
fi
printf 'PASS: first run creates the login mapping without requiring VNC state\n'

existing_config_directory="${fixture_directory}/existing-config"
existing_config="${existing_config_directory}/config"
original_config="${existing_config_directory}/original-config"
vnc_state="${existing_config_directory}/remote_vnc_bluehive3.env"
identity_file="${existing_config_directory}/remote-vnc-id"
known_hosts_file="${existing_config_directory}/remote-vnc-known-hosts"
compute_control_path="${existing_config_directory}/compute-control.sock"
mkdir -p "${existing_config_directory}"
touch "${identity_file}" "${known_hosts_file}"

{
    printf '# user content before legacy aliases\n'
    printf 'Include "%s/conf.d/*.conf"\n\n' "${existing_config_directory}"
    printf 'Host bluehive3 blh3\n'
    printf '    HostName stale-login.invalid\n'
    printf '    User stale_login_user\n'
    printf '    ControlMaster no\n'
    printf '    ControlPath /tmp/stale-login.sock\n\n'
    printf 'Host bluehive_compute3 blhc3\n'
    printf '    HostName stale-compute.invalid\n'
    printf '    User stale_compute_user\n'
    printf '    Port 1\n'
    printf '    IdentityFile /tmp/stale-identity\n'
    printf '    UserKnownHostsFile /tmp/stale-known-hosts\n'
    printf '    HostKeyAlias stale-compute-key\n'
    printf '    ControlPath /tmp/stale-compute.sock\n'
    printf '    ProxyCommand false\n\n'
    printf '# BEGIN unix-scripts bhward\n'
    printf '# Updated by sync_ssh_config.sh\n'
    printf 'Host bhward bhwc\n'
    printf '    HostName bhward.circ.rochester.edu\n'
    printf '    User other_cluster_user\n'
    printf 'Host *\n'
    printf '# END unix-scripts bhward\n\n'
    printf 'Host *\n'
    printf '    User fallback_user\n'
    printf '    Port 65000\n'
    printf '    ControlMaster no\n'
} > "${original_config}"
cp "${original_config}" "${existing_config}"

write_vnc_state \
    "${vnc_state}" test_user bhc001 44321 "${compute_control_path}" \
    "${identity_file}" "${known_hosts_file}" remote-vnc-bluehive3-test
sync_cluster_ssh_config \
    bluehive3 test_user "${existing_config}" "${vnc_state}"

original_config_size="$(wc -c < "${original_config}" | tr -d '[:space:]')"
tail -c "${original_config_size}" "${existing_config}" | cmp - "${original_config}"
assert_ssh_config_value \
    "${existing_config}" bluehive3 hostname bluehive3.circ.rochester.edu
assert_ssh_config_value "${existing_config}" bluehive3 user test_user
assert_ssh_config_value "${existing_config}" blh3 user test_user
assert_ssh_config_value "${existing_config}" bluehive3 controlmaster auto
assert_ssh_config_value \
    "${existing_config}" bluehive3 controlpath \
    "${expected_login_control_path}"
assert_ssh_config_value \
    "${existing_config}" bluehive_compute3 hostname bhc001
assert_ssh_config_value "${existing_config}" blhc3 hostname bhc001
assert_ssh_config_value "${existing_config}" blhc3 user test_user
assert_ssh_config_value "${existing_config}" blhc3 port 44321
assert_ssh_config_value \
    "${existing_config}" blhc3 controlpath "${compute_control_path}"
assert_ssh_config_value \
    "${existing_config}" blhc3 identityfile "${identity_file}"
assert_ssh_config_value \
    "${existing_config}" blhc3 userknownhostsfile "${known_hosts_file}"
assert_ssh_config_value \
    "${existing_config}" blhc3 hostkeyalias remote-vnc-bluehive3-test

proxy_command="$(ssh_config_value "${existing_config}" blhc3 proxycommand)"
[[ "${proxy_command}" == *'/usr/bin/ssh -F /dev/null'* ]]
[[ "${proxy_command}" == *"-S ${expected_login_control_path}"* ]]
[[ "${proxy_command}" == *'-W %h:%p'* ]]
[[ "${proxy_command}" == *'test_user@bluehive3.circ.rochester.edu'* ]]
assert_ssh_config_value \
    "${existing_config}" bhward hostname bhward.circ.rochester.edu
assert_ssh_config_value "${existing_config}" bhward user other_cluster_user
printf 'PASS: managed mappings override later aliases and Host * without changing existing content\n'

idempotent_snapshot="${existing_config_directory}/idempotent-snapshot"
cp "${existing_config}" "${idempotent_snapshot}"
sync_cluster_ssh_config \
    bluehive3 test_user "${existing_config}" "${vnc_state}"
cmp "${existing_config}" "${idempotent_snapshot}"
printf 'PASS: repeated synchronization is byte-for-byte idempotent\n'

write_vnc_state \
    "${vnc_state}" test_user bhc004 44325 "${compute_control_path}" \
    "${identity_file}" "${known_hosts_file}" remote-vnc-bluehive3-test
sync_cluster_ssh_config \
    bluehive3 test_user "${existing_config}" "${vnc_state}"
assert_ssh_config_value "${existing_config}" blhc3 hostname bhc004
assert_ssh_config_value "${existing_config}" blhc3 port 44325
tail -c "${original_config_size}" "${existing_config}" | cmp - "${original_config}"
printf 'PASS: a changed VNC allocation replaces the managed compute mapping\n'

mismatched_directory="${fixture_directory}/mismatched-user"
mismatched_config="${mismatched_directory}/config"
mismatched_state="${mismatched_directory}/remote_vnc_bluehive3.env"
mkdir -p "${mismatched_directory}"
write_vnc_state \
    "${mismatched_state}" another_user bhc009 44329 \
    "${mismatched_directory}/compute-control.sock" \
    "${identity_file}" "${known_hosts_file}" remote-vnc-bluehive3-other
sync_cluster_ssh_config \
    bluehive3 test_user "${mismatched_config}" "${mismatched_state}"
assert_ssh_config_value "${mismatched_config}" bluehive3 user test_user
if awk '
    $1 == "Host" {
        for (field_index = 2; field_index <= NF; field_index++) {
            if ($field_index == "bluehive_compute3" || $field_index == "blhc3") {
                found_compute_mapping = 1
            }
        }
    }
    END { exit found_compute_mapping ? 0 : 1 }
' "${mismatched_config}"; then
    printf 'Compute aliases were generated from another user\047s VNC state\n' >&2
    exit 1
fi
printf 'PASS: a VNC state owned by another user does not create compute aliases\n'
