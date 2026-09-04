#!/usr/bin/env bash

# Run on Linux: bash tests/test_remote_vnc_launch.sh
# All Slurm commands and service launchers are replaced with local fixtures.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
release_directory="${fixture_directory}/release"
service_directory="${fixture_directory}/service"
mock_binary_directory="${fixture_directory}/bin"
mkdir -p "${release_directory}" "${service_directory}/state" \
    "${service_directory}/logs" "${mock_binary_directory}"
cp "${repository_directory}/remote_vnc/environment_common.sh" "${release_directory}/"

for script_name in start_vnc.sh configure_desktop.sh macos_shortcut.sh \
    start_opencodex.sh prepare_environment.sh bh-env.sh provision_environment.sh \
    remote_vnc_job_sshd.sh; do
    printf '#!/usr/bin/env bash\nexit 99\n' > "${release_directory}/${script_name}"
done
for file_name in bluehive-aurora.svg ubuntu-vnc-xfce-g3_24.04.sha256 \
    ubuntu-vnc-xfce-g3_24.04.def environment-packages.txt matlab-products.txt \
    authorized_keys; do
    touch "${release_directory}/${file_name}"
done
cat > "${release_directory}/build_vnc_image.sh" <<'MOCK_BUILD'
#!/usr/bin/env bash
touch "${TEST_IMAGE_MARKER}"
exit 42
MOCK_BUILD
printf '#!/usr/bin/env bash\nexit 0\n' > "${mock_binary_directory}/ssh-keygen"
chmod +x "${release_directory}/"*.sh "${mock_binary_directory}/ssh-keygen"
export PATH="${mock_binary_directory}:${PATH}"
export TEST_IMAGE_MARKER="${fixture_directory}/image-started"

run_job() {
    SLURM_JOB_ID=900001 bash "${repository_directory}/remote_vnc/remote_vnc_job.sh" \
        "${release_directory}" "${service_directory}" /unused-image \
        "${release_directory}/remote_vnc_job_sshd.sh" \
        "${release_directory}/authorized_keys" 1 1 default mutable 1 44422
}

expect_failure() {
    local expected_status="$1"
    shift
    local actual_status=0
    "$@" > "${fixture_directory}/stdout" 2> "${fixture_directory}/stderr" || actual_status=$?
    [[ "${actual_status}" -eq "${expected_status}" ]] || {
        cat "${fixture_directory}/stderr" >&2
        printf 'Expected status %s, got %s\n' "${expected_status}" "${actual_status}" >&2
        exit 1
    }
}

exec 9>"${service_directory}/state/allocation.lock"
flock -n 9
expect_failure 8 run_job
grep -q 'Refusing to start duplicate services' "${fixture_directory}/stderr"
[[ ! -e "${TEST_IMAGE_MARKER}" ]]
flock -u 9
exec 9>&-
expect_failure 42 run_job
[[ -e "${TEST_IMAGE_MARKER}" ]]
grep -q '^LAUNCHER_VERSION=14$' "${service_directory}/state/jobs/900001/managed-launcher.env"
flock -n "${service_directory}/state/allocation.lock" true
printf 'PASS: duplicate allocation rejected before image preparation; lock released on exit\n'

# Exercise the actual SSH payload, replacing only the fixed Slurm binary path.
awk '/<<.REMOTE_START./ {copy=1; next} copy && /^REMOTE_START$/ {exit} copy {print}' \
    "${repository_directory}/remote_vnc.sh" |
    sed "s|^slurm_binary_directory=.*|slurm_binary_directory=\"${mock_binary_directory}\"|" \
    > "${fixture_directory}/remote-start.sh"
for command_name in squeue scancel; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${mock_binary_directory}/${command_name}"
done
printf '#!/usr/bin/env bash\nprintf "900002\\n"\n' > "${mock_binary_directory}/sbatch"
printf '#!/usr/bin/env bash\nprintf "PartitionName=doppelbock QoS=N/A\\n"\n' \
    > "${mock_binary_directory}/scontrol"
chmod +x "${mock_binary_directory}/"*

run_remote_start() {
    bash "${fixture_directory}/remote-start.sh" \
        "${release_directory}" "${service_directory}" /unused-image \
        doppelbock 1 0 1 1 __REMOTE_VNC_SCHEDULER__ 1 1 \
        "${repository_directory}/remote_vnc/remote_vnc_job.sh" \
        "${release_directory}/remote_vnc_job_sshd.sh" \
        "${release_directory}/authorized_keys" \
        remote-vnc-managed-v14:default:mutable:44422:2560x1440 \
        false default mutable 1 44422 2560x1440
}

exec 8>"${service_directory}/state/launch.lock"
flock -n 8
expect_failure 8 run_remote_start
grep -q 'Another VNC launch or restart is in progress' "${fixture_directory}/stderr"
flock -u 8
exec 8>&-
printf 'PASS: concurrent client rejected before job discovery or submission\n'

printf 'fixture app-server startup failure\n' \
    > "${service_directory}/logs/$(id -un)-vnc_900002.err"
expect_failure 4 run_remote_start
grep -q 'fixture app-server startup failure' "${fixture_directory}/stderr"
[[ ! -s "${fixture_directory}/stdout" ]]
flock -n "${service_directory}/state/launch.lock" true
printf 'PASS: failed-job log reaches stderr instead of captured connection record\n'
