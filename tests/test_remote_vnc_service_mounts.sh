#!/usr/bin/env bash

set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf -- "${fixture_directory}"' EXIT

export HOME="${fixture_directory}/host-home"
export SLURM_JOB_ID=900001
mkdir -p "${HOME}/.ssh" "${fixture_directory}/persistent-home"
printf 'host SSH known_hosts fixture\n' > "${HOME}/.ssh/known_hosts"
source "${repository_directory}/remote_vnc/environment_common.sh"

service_tmp_directory="${fixture_directory}/node-local/tmp"
service_options=()
bh_env_append_runtime_options service_options \
    "${fixture_directory}/persistent-home" "${fixture_directory}/runtime" \
    "" service "${service_tmp_directory}"

normal_options=()
bh_env_append_runtime_options normal_options \
    "${fixture_directory}/persistent-home" "${fixture_directory}/runtime" \
    "" normal

admin_options=()
bh_env_append_runtime_options admin_options \
    "${fixture_directory}/persistent-home" "${fixture_directory}/runtime" \
    "" admin

has_option_pair() {
    local options_name="$1"
    local requested_option="$2"
    local requested_value="$3"
    local -n options="$options_name"
    local option_index

    for ((option_index=0; option_index<${#options[@]}-1; option_index++)); do
        [[ "${options[option_index]}" == "${requested_option}" &&
           "${options[option_index+1]}" == "${requested_value}" ]] && return 0
    done
    return 1
}

! has_option_pair service_options --bind '/:/host:ro'
has_option_pair service_options --bind "${service_tmp_directory}:/tmp"
has_option_pair normal_options --bind '/:/host:ro'
! has_option_pair normal_options --bind "${service_tmp_directory}:/tmp"
printf 'PASS: Codex service uses node-local /tmp without /host; normal VNC retains /host\n'

container_home="/home/$(id -un)"
for options_name in service_options normal_options admin_options; do
    has_option_pair "${options_name}" --bind \
        "${HOME}/.ssh:${container_home}/.ssh"
    has_option_pair "${options_name}" --env 'GIT_CONFIG_COUNT=1'
    has_option_pair "${options_name}" --env \
        'GIT_CONFIG_KEY_0=url.git@github.com:.pushInsteadOf'
    has_option_pair "${options_name}" --env \
        'GIT_CONFIG_VALUE_0=https://github.com/'
done
grep -Fxq 'host SSH known_hosts fixture' "${HOME}/.ssh/known_hosts"
printf 'PASS: normal, service and admin containers share host SSH state and GitHub SSH pushes\n'

# Exercise Git's URL selection without contacting GitHub or invoking a helper.
git init -q "${fixture_directory}/repo"
git -C "${fixture_directory}/repo" remote add origin \
    https://github.com/example/project.git
[[ "$(
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0='url.git@github.com:.pushInsteadOf' \
    GIT_CONFIG_VALUE_0=https://github.com/ \
        git -C "${fixture_directory}/repo" remote get-url --push origin
)" == git@github.com:example/project.git ]]
[[ "$(git -C "${fixture_directory}/repo" remote get-url origin)" == \
   https://github.com/example/project.git ]]
printf 'PASS: HTTPS GitHub remotes push through SSH without editing the stored remote\n'

mv "${HOME}/.ssh" "${HOME}/saved-ssh"
no_ssh_options=()
bh_env_append_runtime_options no_ssh_options \
    "${fixture_directory}/persistent-home" "${fixture_directory}/runtime" \
    "" normal
! has_option_pair no_ssh_options --bind \
    "${HOME}/.ssh:${container_home}/.ssh"
mv "${HOME}/saved-ssh" "${HOME}/.ssh"
printf 'PASS: hosts without SSH state do not receive a nonexistent SSH bind\n'

# Exercise the actual SSH bind construction against the service's published path.
awk '/^read_state_value\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "${repository_directory}/remote_vnc/remote_vnc_job_sshd.sh" \
    > "${fixture_directory}/ssh-options.sh"
awk '/^    service_tmp_directory="\$\(/ {copy=1}
     copy && /^    sshd_launch_prefix=/ {exit}
     copy {print}' "${repository_directory}/remote_vnc/remote_vnc_job_sshd.sh" \
    >> "${fixture_directory}/ssh-options.sh"
service_state_file="${fixture_directory}/service.env"
job_state_directory="${fixture_directory}/job"
container_group_file="${fixture_directory}/group"
printf 'SERVICE_TMP_DIRECTORY=%s\n' "${service_tmp_directory}" \
    > "${service_state_file}"
container_options=()
source "${fixture_directory}/ssh-options.sh"
has_option_pair container_options --bind "${service_tmp_directory}:/tmp"
printf 'PASS: container SSH shares the published node-local app-server /tmp\n'

# Existing releases that have no published path still use their shared runtime.
: > "${service_state_file}"
mkdir -p "${job_state_directory}/opencodex/runtime/tmp"
container_options=()
source "${fixture_directory}/ssh-options.sh"
has_option_pair container_options --bind \
    "${job_state_directory}/opencodex/runtime/tmp:/tmp"
printf 'PASS: container SSH supports the earlier shared runtime layout\n'

for invalid_tmp_directory in relative-path "${fixture_directory}/missing"; do
    printf 'SERVICE_TMP_DIRECTORY=%s\n' "${invalid_tmp_directory}" \
        > "${service_state_file}"
    actual_status=0
    (source "${fixture_directory}/ssh-options.sh") \
        > "${fixture_directory}/stdout" 2> "${fixture_directory}/stderr" || actual_status=$?
    [[ "${actual_status}" == 2 ]]
    grep -q 'AI service runtime /tmp is unavailable' "${fixture_directory}/stderr"
done
printf 'PASS: container SSH rejects relative or missing service /tmp paths\n'
