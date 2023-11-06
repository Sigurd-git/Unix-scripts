current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
sshpass -p $PASSWORD ssh bluehive "screen -dmS doppelbock salloc -N 1 -n $1 -p doppelbock -t $2:00:00"
