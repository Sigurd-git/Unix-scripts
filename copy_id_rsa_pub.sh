source ./read_user_password.sh
pubkey=`cat ~/.ssh/id_rsa.pub`
sshpass -p $PASSWORD ssh Bluehive "echo $pubkey >> ~/.ssh/authorized_keys ; chmod 600 ~/.ssh/authorized_keys"