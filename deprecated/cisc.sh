current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
method="push" # Default method is push
if [ "$1" == "--method" ] && [ -n "$2" ]; then
    method=$2
fi

# Connect to VPN with the specified method
printf "$USER\n$PASSWORD\n$method\ny" | /opt/cisco/anyconnect/bin/vpn -s connect vpn.rochester.edu 

# If the method is sms, connect again and input secondary password
if [ "$method" == "sms" ]; then
    # Prompt the user to manually input the secondary password
    read -s -p "Enter secondary password: " SECONDARY_PASSWORD
    printf "$USER\n$PASSWORD\n$SECONDARY_PASSWORD\n" | /opt/cisco/anyconnect/bin/vpn -s connect vpn.rochester.edu 
fi