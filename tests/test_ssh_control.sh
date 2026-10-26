#!/usr/bin/env bash

# Exercise the launcher with real OpenSSH config parsing and a local transport
# stub. No credentials, live control sockets, or network connections are used.
set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
export SSH_CONTROL_TEST_DIRECTORY="${fixture_directory}"
mkdir -p "${fixture_directory}/.ssh"
cp "${repository_directory}/ssh_login_askpass.sh" "${fixture_directory}/ssh_login_askpass.sh"
chmod +x "${fixture_directory}/ssh_login_askpass.sh"

sed -e "s|/usr/bin/ssh|${fixture_directory}/ssh|g" \
    -e 's|${HOME}|${SSH_CONTROL_TEST_DIRECTORY}|g' \
    "${repository_directory}/start_ssh_control.sh" > "${fixture_directory}/start_ssh_control.sh"
sed 's|${HOME}|${SSH_CONTROL_TEST_DIRECTORY}|g' \
    "${repository_directory}/cluster_helpers.sh" > "${fixture_directory}/cluster_helpers.sh"
cat >> "${fixture_directory}/cluster_helpers.sh" <<'EOF'
cluster_control_path() {
    printf '%s/control.sock' "${SSH_CONTROL_TEST_DIRECTORY}"
}
EOF
cat > "${fixture_directory}/read_user_password.sh" <<'EOF'
REMOTE_USER=test_user
PASSWORD="${SSH_CONTROL_TEST_PASSWORD:-}"
EOF
cat > "${fixture_directory}/sync_ssh_config.sh" <<'EOF'
touch "${SSH_CONTROL_TEST_DIRECTORY}/synchronized"
EOF
cat > "${fixture_directory}/ssh" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    if [[ "${argument}" == '-O' ]]; then
        [[ -f "${SSH_CONTROL_TEST_DIRECTORY}/running" ]] || exit 255
        printf 'Master running (pid=1234)\n'
        exit 0
    fi
done
printf '%s\n' "$@" > "${SSH_CONTROL_TEST_DIRECTORY}/arguments"
if [[ -n "${SSH_CONTROL_TEST_PASSWORD:-}" ]]; then
    [[ "${SSH_ASKPASS_REQUIRE:-}" == force ]] || exit 80
    [[ "${REMOTE_SSH_PASSWORD_TARGET:-}" == test_user@bluehive3.circ.rochester.edu ]] || exit 81
    response="$("${SSH_ASKPASS}" "test_user@bluehive3.circ.rochester.edu's password: ")" || exit 82
    [[ "${response}" == "${SSH_CONTROL_TEST_PASSWORD}" ]] || exit 83
    touch "${SSH_CONTROL_TEST_DIRECTORY}/askpass-used"
fi
[[ "${SSH_CONTROL_TEST_STATUS:-0}" -eq 0 ]] || exit "${SSH_CONTROL_TEST_STATUS}"
touch "${SSH_CONTROL_TEST_DIRECTORY}/running"
EOF
chmod +x "${fixture_directory}/ssh"

assert_argument() {
    local expected="$1" argument
    while IFS= read -r argument; do
        [[ "${argument}" != "${expected}" ]] || return 0
    done < "${fixture_directory}/arguments"
    printf 'Missing SSH argument: %s\n' "${expected}" >&2
    return 1
}

run_launcher() {
    local launch_status=0
    rm -f "${fixture_directory}/running" "${fixture_directory}/synchronized" \
        "${fixture_directory}/arguments"
    bash "${fixture_directory}/start_ssh_control.sh" > "${fixture_directory}/output" 2>&1 || launch_status=$?
    if [[ "${launch_status}" -ne 0 ]]; then
        cat "${fixture_directory}/output" >&2
        return "${launch_status}"
    fi
}

run_launcher
assert_argument ConnectTimeout=15
assert_argument ConnectionAttempts=1
assert_argument /dev/null
assert_argument test_user@bluehive3.circ.rochester.edu
[[ -f "${fixture_directory}/synchronized" ]]
printf 'PASS: direct connections use a bounded handshake and the explicit login target\n'

for jump_hosts in campus-gateway 'first-hop,user@last-hop:2222' 'user@[2001:db8::1]:2222' 'ssh://user@last-hop:2222'; do
    printf 'Host bluehive3\n    ProxyJump %s\n' "${jump_hosts}" > "${fixture_directory}/.ssh/config"
    run_launcher
    proxy_command="$(awk '/^ProxyCommand=/{sub(/^ProxyCommand=/, ""); print}' "${fixture_directory}/arguments")"
    [[ -n "${proxy_command}" && "${proxy_command}" != *'-F /dev/null'* ]]
    [[ "${proxy_command}" == *'ClearAllForwardings=yes'* ]]
    # Execute the generated proxy against the transport stub to check quoting,
    # SSH URI handling, and the destination's position in the command.
    /bin/sh -c "${proxy_command}"
    case "${jump_hosts}" in
        campus-gateway) assert_argument campus-gateway ;;
        *2001:db8*) assert_argument 2001:db8::1 ;;
        *) assert_argument last-hop ;;
    esac
    if [[ "${jump_hosts}" == *user@* ]]; then
        assert_argument -l
        assert_argument user
        assert_argument -p
        assert_argument 2222
    fi
    assert_argument '[%h]:%p'
    if [[ "${jump_hosts}" == *,* ]]; then
        assert_argument -J
        assert_argument "${jump_hosts%,*}"
    fi
done
printf 'PASS: single and multiple jump hosts keep alias resolution, ports, and IPv6 intact\n'

cat > "${fixture_directory}/.ssh/config" <<'EOF'
Host bluehive3.circ.rochester.edu
    ProxyCommand ssh -W %h:%p campus-gateway
EOF
run_launcher
assert_argument 'ProxyCommand=ssh -W %h:%p campus-gateway'
printf 'PASS: full-hostname ProxyCommand reaches the launcher unchanged\n'

SSH_CONTROL_TEST_PASSWORD='fixture secret with spaces' run_launcher
[[ -f "${fixture_directory}/askpass-used" && -f "${fixture_directory}/running" ]]
assert_argument NumberOfPasswordPrompts=1
[[ "$(cat "${fixture_directory}/output")" == *'SSH session to bluehive3 is ready.'* ]]
[[ "$(cat "${fixture_directory}/output")" != *'fixture secret'* ]]
printf 'PASS: saved passwords use native askpass without a PTY wrapper or secret output\n'

response="$(REMOTE_SSH_PASSWORD='fixture secret' \
    REMOTE_SSH_PASSWORD_TARGET=test_user@bluehive3.circ.rochester.edu \
    SSH_ASKPASS_PROMPT=none "${fixture_directory}/ssh_login_askpass.sh" \
    "test_user@bluehive3.circ.rochester.edu's password: " 2>/dev/null)"
[[ -z "${response}" ]]
printf 'PASS: informational prompts never receive the saved password\n'

status=0
SSH_CONTROL_TEST_STATUS=255 run_launcher || status=$?
[[ "${status}" -eq 255 && ! -f "${fixture_directory}/synchronized" ]]
[[ "$(cat "${fixture_directory}/output")" == *'failed (status 255)'* ]]
printf 'PASS: failed connections retain the SSH status and do not synchronize aliases\n'

touch "${fixture_directory}/running"
rm -f "${fixture_directory}/arguments"
bash "${fixture_directory}/start_ssh_control.sh" > "${fixture_directory}/output" 2>&1
[[ ! -f "${fixture_directory}/arguments" && -f "${fixture_directory}/synchronized" ]]
[[ "$(cat "${fixture_directory}/output")" == *'Reusing SSH session'* ]]
printf 'PASS: a running control master is reused without another authentication\n'
