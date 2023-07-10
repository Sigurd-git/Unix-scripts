#!/bin/bash

# read first 2 rows
while IFS= read -r line1; do
    IFS= read -r line2
    # set environment variables
    export USER="$line1"
    export PASSWORD="$line2"
    break
done < user_password.txt

echo "USER: $USER"
echo "PASSWORD: $PASSWORD"
