#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

release_directory="${BH_ENV_RELEASE_DIRECTORY:-/opt/bh-env-release}"
build_directory="${BH_ENV_BUILD_DIRECTORY:-/var/tmp/bh-env-build}"
package_list_file="${release_directory}/environment-packages.txt"
matlab_products_file="${release_directory}/matlab-products.txt"
matlab_release="R2025b"
matlab_destination="/opt/matlab/${matlab_release}"
node_version="22.23.2"
node_archive_name="node-v${node_version}-linux-x64.tar.xz"
node_archive_url="https://nodejs.org/dist/v${node_version}/${node_archive_name}"
node_archive_sha256="d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307"
node_destination="/opt/node-v${node_version}"
opencodex_version="2.39.0"
codex_cli_version="0.150.1"
codex_target="x86_64-unknown-linux-musl"
codex_package_name="codex-package-${codex_target}.tar.gz"
codex_package_url="https://releases.openai.com/codex/releases/${codex_cli_version}/${codex_package_name}"
codex_package_sha256="00aba704f029f6dc0d948be407a756e0c97cc840132fd691353b2c6b0a505b17"
codex_seed_home="/opt/codex-home"
codex_standalone_root="${codex_seed_home}/packages/standalone"
codex_release_name="${codex_cli_version}-${codex_target}"
export PATH="/usr/local/cuda/bin:${matlab_destination}/bin:${PATH}"
cuda_keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"
chrome_deb_url="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
chatgpt_deb_url="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb"
mpm_url="https://www.mathworks.com/mpm/glnxa64/mpm"
manifest_directory="/etc/bh-env"
manifest_file="${manifest_directory}/build-manifest.env"
temporary_manifest="${build_directory}/build-manifest.env"

[[ "$(id -u)" -eq 0 ]] || {
    printf 'Environment provisioning requires an Apptainer fakeroot shell.\n' >&2
    exit 2
}
[[ "$(uname -m)" == "x86_64" ]] || {
    printf 'The environment recipe supports Linux x86_64 only.\n' >&2
    exit 2
}
for required_file in "${package_list_file}" "${matlab_products_file}"; do
    [[ -r "${required_file}" ]] || {
        printf 'Required recipe file is missing: %s\n' "${required_file}" >&2
        exit 2
    }
done

mkdir -p "${build_directory}" "${manifest_directory}"
chmod 700 "${build_directory}"

download_file() {
    local source_url="$1"
    local destination_file="$2"

    curl --fail --location --retry 3 --retry-all-errors \
        --connect-timeout 30 --output "${destination_file}" "${source_url}"
    [[ -s "${destination_file}" ]] || {
        printf 'Downloaded file is empty: %s\n' "${source_url}" >&2
        return 1
    }
}

record_download() {
    local record_name="$1"
    local downloaded_file="$2"

    printf '%s_SHA256=%s\n' "${record_name}" \
        "$(sha256sum "${downloaded_file}" | awk '{ print $1; exit }')" \
        >> "${temporary_manifest}"
}

mapfile -t apt_packages < <(
    awk 'NF && $1 !~ /^#/ { print $1 }' "${package_list_file}"
)
mapfile -t matlab_products < <(
    awk 'NF && $1 !~ /^#/ { print $1 }' "${matlab_products_file}"
)
(( ${#apt_packages[@]} > 0 )) || {
    printf 'The apt package list is empty.\n' >&2
    exit 2
}
(( ${#matlab_products[@]} > 0 )) || {
    printf 'The MATLAB product list is empty.\n' >&2
    exit 2
}

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
policy_rc_backup="${build_directory}/policy-rc.d.original"
policy_rc_existed=false
if [[ -e /usr/sbin/policy-rc.d ]]; then
    cp -a /usr/sbin/policy-rc.d "${policy_rc_backup}"
    policy_rc_existed=true
fi
restore_policy_rc() {
    if [[ "${policy_rc_existed}" == "true" ]]; then
        cp -a "${policy_rc_backup}" /usr/sbin/policy-rc.d
    else
        rm -f /usr/sbin/policy-rc.d
    fi
}
trap restore_policy_rc EXIT
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d

printf '[bh-env] Installing Ubuntu development and desktop packages.\n'
apt-get update
apt-get install -y --no-install-recommends "${apt_packages[@]}"
locale-gen en_US.UTF-8
fc-cache -f
if [[ ! -s /etc/machine-id ]]; then
    dbus-uuidgen --ensure=/etc/machine-id
fi

node_archive="${build_directory}/${node_archive_name}"
download_file "${node_archive_url}" "${node_archive}"
actual_node_archive_sha256="$(
    sha256sum "${node_archive}" | awk '{ print $1; exit }'
)"
[[ "${actual_node_archive_sha256}" == "${node_archive_sha256}" ]] || {
    printf 'Node.js archive checksum mismatch: expected %s, found %s.\n' \
        "${node_archive_sha256}" "${actual_node_archive_sha256}" >&2
    exit 3
}
printf '[bh-env] Installing Node.js %s.\n' "${node_version}"
mkdir -p "${node_destination}"
tar -xJf "${node_archive}" --strip-components=1 -C "${node_destination}"
for node_command in node npm npx corepack; do
    [[ -x "${node_destination}/bin/${node_command}" ]] || {
        printf 'Node.js command is missing: %s\n' "${node_command}" >&2
        exit 3
    }
    ln -sfn "${node_destination}/bin/${node_command}" \
        "/usr/local/bin/${node_command}"
done

printf '[bh-env] Installing OpenCodex %s.\n' "${opencodex_version}"
npm install --global --prefix /usr/local --omit=dev --no-audit --no-fund \
    "@bitkyc08/opencodex@${opencodex_version}"

codex_package_archive="${build_directory}/${codex_package_name}"
download_file "${codex_package_url}" "${codex_package_archive}"
actual_codex_package_sha256="$(
    sha256sum "${codex_package_archive}" | awk '{ print $1; exit }'
)"
[[ "${actual_codex_package_sha256}" == "${codex_package_sha256}" ]] || {
    printf 'Codex package checksum mismatch: expected %s, found %s.\n' \
        "${codex_package_sha256}" \
        "${actual_codex_package_sha256}" >&2
    exit 3
}
printf '[bh-env] Installing standalone Codex CLI %s.\n' \
    "${codex_cli_version}"
codex_release_directory="${codex_standalone_root}/releases/${codex_release_name}"
codex_staging_directory="${codex_standalone_root}/releases/.staging-${codex_release_name}"
[[ ! -e "${codex_release_directory}" && ! -L "${codex_release_directory}" ]] || {
    printf 'Codex release destination already exists: %s\n' \
        "${codex_release_directory}" >&2
    exit 3
}
mkdir -p "${codex_staging_directory}"
tar -xzf "${codex_package_archive}" -C "${codex_staging_directory}"
for codex_executable in \
    bin/codex bin/codex-code-mode-host codex-path/rg codex-resources/bwrap; do
    [[ -f "${codex_staging_directory}/${codex_executable}" ]] || {
        printf 'Codex package is missing: %s\n' "${codex_executable}" >&2
        exit 3
    }
    chmod 0755 "${codex_staging_directory}/${codex_executable}"
done
[[ -f "${codex_staging_directory}/codex-package.json" ]] || {
    printf 'Codex package metadata is missing.\n' >&2
    exit 3
}
ln -s bin/codex "${codex_staging_directory}/codex"
mv "${codex_staging_directory}" "${codex_release_directory}"
ln -s "releases/${codex_release_name}" "${codex_standalone_root}/current"
ln -sfn "${codex_standalone_root}/current/bin/codex" /usr/local/bin/codex
[[ "$(codex --version | awk '{ print $NF; exit }')" == \
    "${codex_cli_version}" ]] || {
    printf 'Standalone Codex CLI version validation failed.\n' >&2
    exit 3
}

cuda_keyring_deb="${build_directory}/cuda-keyring.deb"
download_file "${cuda_keyring_url}" "${cuda_keyring_deb}"
dpkg -i "${cuda_keyring_deb}"
apt-get update
printf '[bh-env] Installing CUDA 12.5 development components.\n'
apt-get install -y --no-install-recommends \
    cuda-compiler-12-5 \
    cuda-command-line-tools-12-5 \
    cuda-libraries-dev-12-5

chrome_deb="${build_directory}/google-chrome-stable.deb"
chatgpt_deb="${build_directory}/chatgpt.deb"
download_file "${chrome_deb_url}" "${chrome_deb}"
download_file "${chatgpt_deb_url}" "${chatgpt_deb}"
printf '[bh-env] Installing Google Chrome and ChatGPT.\n'
apt-get install -y "${chrome_deb}" "${chatgpt_deb}"

uv_installer="${build_directory}/uv-installer.sh"
pixi_installer="${build_directory}/pixi-installer.sh"
download_file "https://astral.sh/uv/install.sh" "${uv_installer}"
download_file "https://pixi.sh/install.sh" "${pixi_installer}"
printf '[bh-env] Installing uv and pixi.\n'
env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 \
    /bin/sh "${uv_installer}"
env PIXI_HOME=/opt/pixi PIXI_NO_PATH_UPDATE=1 \
    /bin/bash "${pixi_installer}"
[[ -x /opt/pixi/bin/pixi ]] || {
    printf 'The pixi installer did not create /opt/pixi/bin/pixi.\n' >&2
    exit 3
}
ln -sfn /opt/pixi/bin/pixi /usr/local/bin/pixi

mpm_executable="${build_directory}/mpm"
download_file "${mpm_url}" "${mpm_executable}"
install -m 0755 "${mpm_executable}" /usr/local/bin/mpm
printf '[bh-env] Installing MATLAB %s and selected toolboxes.\n' \
    "${matlab_release}"
/usr/local/bin/mpm install \
    "--release=${matlab_release}" \
    "--destination=${matlab_destination}" \
    --products "${matlab_products[@]}"
[[ -x "${matlab_destination}/bin/matlab" ]] || {
    printf 'MATLAB installation is missing its executable: %s\n' \
        "${matlab_destination}/bin/matlab" >&2
    exit 3
}
ln -sfn "${matlab_destination}/bin/matlab" /usr/local/bin/matlab

cat > /etc/profile.d/bh-env.sh <<'PROFILE'
export PATH="/usr/local/cuda/bin:/opt/matlab/R2025b/bin:${PATH}"
if [ -z "${MLM_LICENSE_FILE:-}" ] &&
   [ -r /gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2025b/licenses/network.lic ]; then
    export MLM_LICENSE_FILE=/gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2025b/licenses/network.lic
fi
PROFILE
chmod 644 /etc/profile.d/bh-env.sh

restore_policy_rc
trap - EXIT
apt-get clean
rm -rf /var/lib/apt/lists/*
ldconfig

for required_command in \
    fc-list fish gcc g++ gfortran git screen ssh node npm ocx codex uv pixi nvcc \
    google-chrome-stable chatgpt matlab mpm vncserver xdotool xfce4-session; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        printf 'Provisioned command is unavailable: %s\n' \
            "${required_command}" >&2
        exit 4
    }
done
cjk_font_count="$(fc-list :lang=zh | wc -l)"
(( cjk_font_count > 0 )) || {
    printf 'Provisioned environment has no Chinese-capable fonts.\n' >&2
    exit 4
}
matlab_splash_library="${matlab_destination}/bin/glnxa64/splash/coreui/libmwSplashScreenImpl.so"
[[ -r "${matlab_splash_library}" ]] || {
    printf 'MATLAB splash library is missing: %s\n' \
        "${matlab_splash_library}" >&2
    exit 4
}
missing_matlab_splash_dependencies="$(
    LC_ALL=C ldd "${matlab_splash_library}" |
        awk '$2 == "=>" && $3 == "not" && $4 == "found" { print $1 }'
)"
[[ -z "${missing_matlab_splash_dependencies}" ]] || {
    printf 'MATLAB splash dependencies are missing: %s\n' \
        "${missing_matlab_splash_dependencies//$'\n'/, }" >&2
    exit 4
}

: > "${temporary_manifest}"
printf 'SCHEMA_VERSION=1\n' >> "${temporary_manifest}"
printf 'RECIPE_DIGEST=%s\n' "${BH_ENV_RECIPE_DIGEST:-unknown}" \
    >> "${temporary_manifest}"
printf 'BUNDLE_DIGEST=%s\n' "${BH_ENV_BUNDLE_DIGEST:-unknown}" \
    >> "${temporary_manifest}"
printf 'BUILT_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    >> "${temporary_manifest}"
printf 'MATLAB_RELEASE=%s\n' "${matlab_release}" \
    >> "${temporary_manifest}"
printf 'MATLAB_PRODUCTS=%s\n' "${matlab_products[*]}" \
    >> "${temporary_manifest}"
printf 'NODE_VERSION=%s\n' "$(node --version)" \
    >> "${temporary_manifest}"
printf 'NPM_VERSION=%s\n' "$(npm --version)" \
    >> "${temporary_manifest}"
printf 'OPENCODEX_VERSION=%s\n' \
    "$(ocx --version | awk '{ print $NF; exit }')" \
    >> "${temporary_manifest}"
printf 'CODEX_CLI_VERSION=%s\n' \
    "$(codex --version | awk '{ print $NF; exit }')" \
    >> "${temporary_manifest}"
record_download NODE_ARCHIVE "${node_archive}"
record_download CODEX_PACKAGE "${codex_package_archive}"
printf 'CUDA_TOOLKIT_VERSION=%s\n' \
    "$(nvcc --version | awk '/release/ { sub(/.*release /, ""); sub(/,.*/, ""); print; exit }')" \
    >> "${temporary_manifest}"
printf 'CUDA_COMPILER_PACKAGE=%s\n' \
    "$(dpkg-query -W -f='${Version}' cuda-compiler-12-5)" \
    >> "${temporary_manifest}"
printf 'GCC_VERSION=%s\n' "$(gcc -dumpfullversion)" \
    >> "${temporary_manifest}"
printf 'FISH_VERSION=%s\n' "$(fish --version | awk '{ print $NF; exit }')" \
    >> "${temporary_manifest}"
printf 'CJK_FONT_COUNT=%s\n' "${cjk_font_count}" \
    >> "${temporary_manifest}"
printf 'MATLAB_SPLASH_DEPENDENCIES=resolved\n' \
    >> "${temporary_manifest}"
printf 'CHROME_VERSION=%s\n' \
    "$(dpkg-query -W -f='${Version}' google-chrome-stable)" \
    >> "${temporary_manifest}"
chatgpt_package_name="$(dpkg-deb -f "${chatgpt_deb}" Package)"
printf 'CHATGPT_PACKAGE=%s\n' "${chatgpt_package_name}" \
    >> "${temporary_manifest}"
printf 'CHATGPT_VERSION=%s\n' \
    "$(dpkg-query -W -f='${Version}' "${chatgpt_package_name}")" \
    >> "${temporary_manifest}"
printf 'UV_VERSION=%s\n' "$(uv --version | awk '{ print $2; exit }')" \
    >> "${temporary_manifest}"
printf 'PIXI_VERSION=%s\n' "$(pixi --version | awk '{ print $2; exit }')" \
    >> "${temporary_manifest}"
record_download CUDA_KEYRING "${cuda_keyring_deb}"
record_download CHROME_DEB "${chrome_deb}"
record_download CHATGPT_DEB "${chatgpt_deb}"
record_download UV_INSTALLER "${uv_installer}"
record_download PIXI_INSTALLER "${pixi_installer}"
record_download MPM "${mpm_executable}"
printf 'UV_BINARY_SHA256=%s\n' "$(sha256sum /usr/local/bin/uv | awk '{ print $1 }')" \
    >> "${temporary_manifest}"
printf 'PIXI_BINARY_SHA256=%s\n' "$(sha256sum /opt/pixi/bin/pixi | awk '{ print $1 }')" \
    >> "${temporary_manifest}"
printf 'MPM_BINARY_SHA256=%s\n' "$(sha256sum /usr/local/bin/mpm | awk '{ print $1 }')" \
    >> "${temporary_manifest}"
install -m 0444 "${temporary_manifest}" "${manifest_file}"
dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort \
    > "${manifest_directory}/dpkg-packages.txt"
chmod 0444 "${manifest_directory}/dpkg-packages.txt"

printf '[bh-env] Environment provisioning completed.\n'
