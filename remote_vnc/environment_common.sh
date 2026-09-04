#!/usr/bin/env bash

# Shared helpers for the mutable BlueHive Apptainer environments.

bh_env_validate_name() {
    local environment_name="$1"

    [[ "${environment_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

bh_env_load_apptainer() {
    if command -v apptainer >/dev/null 2>&1; then
        return 0
    fi

    [[ -r /etc/profile.d/modules.sh ]] || {
        printf 'Environment Modules initialization is unavailable.\n' >&2
        return 1
    }
    # BlueHive's module init can define a usable `module` function while
    # returning nonzero because an inherited helper function is unavailable.
    # shellcheck disable=SC1091
    source /etc/profile.d/modules.sh 2>/dev/null || true
    type module >/dev/null 2>&1 || {
        printf 'Environment Modules initialization failed.\n' >&2
        return 1
    }
    module purge
    module load apptainer/1.4.1
    command -v apptainer >/dev/null 2>&1
}

bh_env_require_slurm_allocation() {
    local current_cgroup

    [[ -n "${SLURM_JOB_ID:-}" ]] || {
        printf 'This command must run inside a Slurm allocation.\n' >&2
        return 1
    }
    [[ -r /proc/self/cgroup ]] || {
        printf 'The current process cgroup is unavailable.\n' >&2
        return 1
    }
    current_cgroup="$(tr '\n' ';' < /proc/self/cgroup)"
    [[ "${current_cgroup}" == *"/job_${SLURM_JOB_ID}/"* ]] || {
        printf 'The current process is outside Slurm Job %s: %s\n' \
            "${SLURM_JOB_ID}" "${current_cgroup}" >&2
        return 1
    }
}

bh_env_environment_directory() {
    local user_service_directory="$1"
    local environment_name="$2"

    printf '%s/environments/%s\n' \
        "${user_service_directory%/}" "${environment_name}"
}

bh_env_read_current_generation() {
    local environment_directory="$1"
    local current_link="${environment_directory}/current"
    local canonical_environment_directory
    local generation_directory

    [[ -L "${current_link}" ]] || return 1
    canonical_environment_directory="$(readlink -f "${environment_directory}")" ||
        return 1
    generation_directory="$(readlink -f "${current_link}")" || return 1
    case "${generation_directory}" in
        "${canonical_environment_directory}/generations/"*) ;;
        *) return 1 ;;
    esac
    [[ -d "${generation_directory}/rootfs" ]] || return 1
    printf '%s\n' "${generation_directory}"
}

bh_env_map_host_path() {
    local requested_path="$1"
    local host_home="${2:-${HOME:-}}"
    local absolute_path

    [[ "${requested_path}" == /* ]] || requested_path="${PWD}/${requested_path}"
    absolute_path="$(readlink -m "${requested_path}")"

    if [[ -n "${host_home}" && "${absolute_path}" == "${host_home}" ]]; then
        printf '/bluehive-home\n'
    elif [[ -n "${host_home}" && "${absolute_path}" == "${host_home}/"* ]]; then
        printf '/bluehive-home/%s\n' "${absolute_path#"${host_home}/"}"
    elif [[ "${absolute_path}" == /gpfs/fs1 ||
            "${absolute_path}" == /gpfs/fs1/* ||
            "${absolute_path}" == /gpfs/fs2 ||
            "${absolute_path}" == /gpfs/fs2/* ||
            "${absolute_path}" == /scratch ||
            "${absolute_path}" == /scratch/* ]]; then
        printf '%s\n' "${absolute_path}"
    else
        printf '/host%s\n' "${absolute_path}"
    fi
}

bh_env_append_runtime_options() {
    local options_array_name="$1"
    local persistent_home="$2"
    local runtime_directory="$3"
    local display_value="${4:-}"
    local access_mode="${5:-normal}"
    local current_user
    local host_home
    local container_home
    local container_tmp_directory
    local bind_path
    local slurm_variable_name
    local -n runtime_options="${options_array_name}"

    current_user="$(id -un)"
    host_home="${HOME:?HOME is required}"
    container_home="/home/${current_user}"

    [[ -d "${persistent_home}" ]] || {
        printf 'Persistent container home is missing: %s\n' \
            "${persistent_home}" >&2
        return 1
    }
    mkdir -p "${runtime_directory}"
    chmod 700 "${runtime_directory}"

    runtime_options=(exec)
    if [[ "${access_mode}" == "admin" ]]; then
        runtime_options+=(--writable --fakeroot)
    elif [[ "${access_mode}" == "service" ]]; then
        runtime_options+=(--fakeroot)
    elif [[ "${access_mode}" != "normal" ]]; then
        printf 'Unknown container access mode: %s\n' "${access_mode}" >&2
        return 1
    fi

    if [[ "${access_mode}" != "admin" ]] &&
       { [[ -n "${SLURM_JOB_GPUS:-}" ]] ||
         [[ -n "${CUDA_VISIBLE_DEVICES:-}" &&
            "${CUDA_VISIBLE_DEVICES}" != "NoDevFiles" ]]; }; then
        runtime_options+=(--nv)
    fi

    runtime_options+=(
        --cleanenv
        --home "${persistent_home}:${container_home}"
        --bind "/:/host:ro"
        --bind "${host_home}:/bluehive-home"
    )
    if [[ "${access_mode}" == "admin" ||
          "${access_mode}" == "service" ]]; then
        container_tmp_directory="${runtime_directory}/tmp"
        mkdir -p "${container_tmp_directory}"
        chmod 1777 "${container_tmp_directory}"
        runtime_options+=(
            --bind "${container_tmp_directory}:/tmp"
            --env "TMPDIR=/tmp"
            --env "TMP=/tmp"
            --env "TEMP=/tmp"
        )
    fi
    for bind_path in /gpfs/fs1 /gpfs/fs2 /scratch; do
        [[ -d "${bind_path}" ]] &&
            runtime_options+=(--bind "${bind_path}:${bind_path}")
    done

    runtime_options+=(
        --env "USER=${current_user}"
        --env "LOGNAME=${current_user}"
        --env "BH_ENV_ACTIVE=1"
        --env "XDG_CONFIG_HOME=${container_home}/.config"
        --env "XDG_CACHE_HOME=${container_home}/.cache"
        --env "XDG_DATA_HOME=${container_home}/.local/share"
        --env "XDG_RUNTIME_DIR=${runtime_directory}"
        --env "LANG=C.UTF-8"
        --env "TERM=${TERM:-xterm-256color}"
        --env "PATH=/usr/local/cuda/bin:/opt/matlab/R2025b/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        --env "MLM_LICENSE_FILE=${MLM_LICENSE_FILE:-/gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2025b/licenses/network.lic}"
    )
    [[ -n "${display_value}" ]] &&
        runtime_options+=(--env "DISPLAY=${display_value}")
    for slurm_variable_name in \
        CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES \
        SLURM_CLUSTER_NAME SLURM_CPUS_PER_TASK SLURM_JOB_ACCOUNT SLURM_JOB_ID \
        SLURM_JOB_GPUS SLURM_JOB_NAME SLURM_JOB_NODELIST SLURM_JOB_PARTITION \
        SLURM_GPUS SLURM_GPUS_ON_NODE SLURM_MEM_PER_NODE SLURM_STEP_GPUS \
        SLURM_SUBMIT_DIR SLURM_TMPDIR; do
        if [[ -n "${!slurm_variable_name:-}" ]]; then
            runtime_options+=(
                --env "${slurm_variable_name}=${!slurm_variable_name}"
            )
        fi
    done
    for slurm_variable_name in \
        DBUS_SESSION_BUS_ADDRESS SSH_AUTH_SOCK XAUTHORITY; do
        if [[ -n "${!slurm_variable_name:-}" ]]; then
            runtime_options+=(
                --env "${slurm_variable_name}=${!slurm_variable_name}"
            )
        fi
    done
}
