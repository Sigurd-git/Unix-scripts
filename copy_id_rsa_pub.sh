current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
pubkey=`cat ~/.ssh/id_rsa.pub`
sshpass -p $PASSWORD ssh-copy-id bluehive