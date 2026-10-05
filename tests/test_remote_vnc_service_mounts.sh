#!/usr/bin/env bash

set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf -- "${fixture_directory}"' EXIT

export HOME="${fixture_directory}/host-home"
export SLURM_JOB_ID=900001
mkdir -p "${HOME}" "${fixture_directory}/persistent-home"
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
