#!/usr/bin/env bash

cluster_supported() {
    case "$1" in
        bluehive|bluehive3|bhward)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

cluster_supported_list() {
    printf "bluehive, bluehive3, bhward"
}

cluster_hostname() {
    case "$1" in
        bluehive)
            printf "bluehive.circ.rochester.edu"
            ;;
        bluehive3)
            printf "bluehive3.circ.rochester.edu"
            ;;
        bhward)
            printf "bhward.circ.rochester.edu"
            ;;
        *)
            echo "Error: Unknown cluster '$1'. Supported clusters: $(cluster_supported_list)" >&2
            return 1
            ;;
    esac
}

cluster_compute_host() {
    case "$1" in
        bluehive)
            printf "bluehive_compute"
            ;;
        bluehive3)
            printf "bluehive_compute3"
            ;;
        bhward)
            printf "bhward_compute"
            ;;
        *)
            echo "Error: Unknown cluster '$1'. Supported clusters: $(cluster_supported_list)" >&2
            return 1
            ;;
    esac
}

cluster_shortcut() {
    case "$1" in
        bluehive)
            printf "blhc"
            ;;
        bluehive3)
            printf "blhc3"
            ;;
        bhward)
            printf "bhwc"
            ;;
        *)
            echo "Error: Unknown cluster '$1'. Supported clusters: $(cluster_supported_list)" >&2
            return 1
            ;;
    esac
}

cluster_control_path() {
    local cluster_name="$1"
    local local_user_id

    require_cluster "$cluster_name" || return 1
    local_user_id="$(id -u)" || return 1
    printf '/tmp/unix-scripts-login-%s-%s.sock' "$local_user_id" "$cluster_name"
}

# Import only the login route. User aliases must not replace the launchers'
# explicit username, hostname, control socket, or forwarding settings.
cluster_login_proxy_config() {
    local cluster_name="$1"
    local remote_user_name="$2"
    local ssh_config_file="${3:-${HOME}/.ssh/config}"
    local login_hostname host_alias rendered_configuration proxy_config

    login_hostname="$(cluster_hostname "${cluster_name}")" || return 1
    [[ -f "${ssh_config_file}" ]] || return 0
    for host_alias in "${cluster_name}" "${login_hostname}"; do
        rendered_configuration="$(
            /usr/bin/ssh -G -T -F "${ssh_config_file}" \
                -o "HostName=${login_hostname}" -l "${remote_user_name}" \
                "${host_alias}"
        )" || return 1
        proxy_config="$(awk '
            $1 == "proxyjump" || $1 == "proxycommand" { print; exit }
        ' <<< "${rendered_configuration}")"
        if [[ -n "${proxy_config}" ]]; then
            printf '%s\n' "${proxy_config}"
            return 0
        fi
    done
}

require_cluster() {
    if ! cluster_supported "$1"; then
        echo "Error: Unknown cluster '$1'. Supported clusters: $(cluster_supported_list)" >&2
        return 1
    fi
}
