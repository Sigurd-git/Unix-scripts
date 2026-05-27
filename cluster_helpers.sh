#!/bin/bash

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

require_cluster() {
    if ! cluster_supported "$1"; then
        echo "Error: Unknown cluster '$1'. Supported clusters: $(cluster_supported_list)" >&2
        return 1
    fi
}
