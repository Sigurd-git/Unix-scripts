source ./read_user_password.sh
sshpass -p $PASSWORD ssh Bluehive "screen -dmS dmi salloc -N 1 -n $1 -p dmi -t $2:00:00"

