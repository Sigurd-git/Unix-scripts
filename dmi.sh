current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
source $current_path/start_ssh_control.sh 
sshpass -p $PASSWORD ssh bluehive "screen -dmS dmi salloc -N 1 -n $1 -p dmi -t $2:00:00"

