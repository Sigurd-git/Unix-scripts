source ./read_user_password.sh
sshpass -p $PASSWORD ssh Bluehive "screen -dmS doppelbock salloc -N 1 -n $1 -p doppelbock -t $2:00:00"
