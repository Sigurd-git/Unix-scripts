#!/usr/bin/env bash
set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
release_directory="${repository_directory}/remote_vnc"
export SLURM_JOB_ID=900005
export BH_ENV_HOST_COMMANDS_FILE="${fixture_directory}/commands.sh"
printf 'alias sq="squeue --me"\nslab() { squeue --me; }\ncustom_tool() { printf "custom\\n"; }\n' > "${BH_ENV_HOST_COMMANDS_FILE}"
host_home="${fixture_directory}/host"
environment_home="${fixture_directory}/container"
container_home="${environment_home}"
container_ssh_host_directory="${environment_home}/.local/state/remote-vnc/ssh/${SLURM_JOB_ID}"
container_ssh_directory="${container_ssh_host_directory}"
container_command_host_directory="${container_ssh_host_directory}/bin"
container_command_directory="${container_command_host_directory}"
container_host_proxy_source="${release_directory}/container_host_proxy.sh"
container_group_file="${container_ssh_host_directory}/group"
container_ssh_entry_host_file="${container_ssh_host_directory}/entry.sh"
runtime_image_path="${fixture_directory}/rootfs"
runtime_directory="${fixture_directory}/runtime"
environment_name=default
environment_generation=fixture
current_user="$(id -un)"
display_value=:41
mkdir -p "${runtime_image_path}/etc" "${fixture_directory}/slurm" "${environment_home}/.local/bin" "${host_home}"
printf 'root:x:0:\ntty:x:5:\n' > "${runtime_image_path}/etc/group"
cat > "${fixture_directory}/slurm/squeue" <<'MOCK'
#!/usr/bin/env bash
printf 'SLURM fixture: %s\n' "$*"
MOCK
chmod +x "${fixture_directory}/slurm/squeue"
export PATH="${fixture_directory}/slurm:${PATH}"
bh_env_find_slurm_executable() { command -v "$1"; }
awk '/^write_container_ssh_files\(\)/ {copy=1} copy {print} copy && /^}/ {exit}' \
    "${release_directory}/remote_vnc_job_sshd.sh" > "${fixture_directory}/installer.sh"
source "${fixture_directory}/installer.sh"
write_container_ssh_files
cat > "${environment_home}/.local/bin/bluehive-host-shell" <<MOCK
#!/usr/bin/env bash
export PATH='${fixture_directory}/slurm':\$PATH
exec /bin/bash -c "\$1"
MOCK
chmod +x "${environment_home}/.local/bin/bluehive-host-shell"
SSH_ORIGINAL_COMMAND='command -v squeue sq slab bh-host custom_tool; sq; slab; custom_tool' \
    bash "${container_ssh_entry_host_file}" > "${fixture_directory}/output"
grep -qx "${container_command_directory}/squeue" "${fixture_directory}/output"
grep -qx "${container_command_directory}/sq" "${fixture_directory}/output"
grep -qx 'SLURM fixture: --me' "${fixture_directory}/output"
grep -qx custom "${fixture_directory}/output"
[[ -f "${environment_home}/.config/fish/conf.d/remote-vnc-host-commands.fish" ]]
printf 'PASS: generated SSH entry installs, discovers and executes Slurm and custom command wrappers\n'
