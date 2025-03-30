#!/bin/bash
#$1 is dmi or dop
#if dmi, partition is dmi
#if dop, partition is doppelbock
current_path="$(dirname "$0")"
source $current_path/start_ssh_control.sh -p $1
code -n --remote ssh-remote+bhward_compute /home/$USER





