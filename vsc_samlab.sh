#!/bin/bash
#$1 is dmi or dop
#if dmi, partition is dmi
#if dop, partition is doppelbock
current_path="$(dirname "$0")"
source $current_path/read_user_password.sh

sshpass -p '$PASSWORD' ssh -fN Bluehive

if [ "$1" = "dmi" ]
then
    code -n --remote ssh-remote+Bluehive_compute_dmi /home/$USER
else
    code -n --remote ssh-remote+Bluehive_compute_doppelbock /home/$USER
fi





