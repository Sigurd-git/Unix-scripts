#!/bin/bash
current_path="$(dirname "$0")"
# read first 2 rows
while IFS= read -r line1; do
    IFS= read -r line2
    # set environment variables
    export USER="$line1"
    
    # Check if password was read successfully, if not prompt for manual input
    if [ -z "$line2" ] && [ -z "$PASSWORD" ]; then
        echo "Password not found in file. Please enter password manually:"
        read -s -p "Password: " line2
        echo  # Add newline after password input
    fi
    
    export PASSWORD="$line2"
    break
done < $current_path/user_password.txt

echo "USER: $USER"
# echo "PASSWORD: $PASSWORD"
