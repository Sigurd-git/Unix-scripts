current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
#set default values to be 32 cpu cores 12 hours and 32GB of memory
if [ -z "$1" ]
then
    set -- 32 12 32000
fi
sshpass -p $PASSWORD ssh bhward "screen -dmS dmi salloc -N 1 -n $1 -p dmi -t $2:00:00 --mem $3"

