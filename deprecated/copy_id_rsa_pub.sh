#!/bin/bash
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/read_user_password.sh"
source "$repo_dir/cluster_helpers.sh"

CLUSTER="${1:-bluehive3}"
require_cluster "$CLUSTER" || exit 1

sshpass -p "$PASSWORD" ssh-copy-id "$CLUSTER"
