#!/bin/bash
#$1 is dmi or dop
#if dmi, partition is dmi
#if dop, partition is doppelbock
current_path="$(dirname "$0")"
source $current_path/read_user_password.sh

if [ "$1" = "dmi" ]
then
    code -n --remote ssh-remote+Bluehive_compute_dmi /home/$USER
else
    code -n --remote ssh-remote+Bluehive_compute_doppelbock /home/$USER
fi


platform=$(uname -s)

if [[ $platform == "Darwin" ]]; then
    echo $PASSWORD | pbcopy
elif [[ $platform == "Linux" ]]; then
    if command -v xclip &> /dev/null; then
        echo $PASSWORD | xclip -selection clipboard
    else
        echo "Unable to copy to clipboard. Please install 'xclip'."
    fi
else
    echo "Unsupported platform: $platform"
fi




