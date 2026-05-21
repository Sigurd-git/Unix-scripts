#!/bin/bash

# Default values
CLUSTER="bluehive"
NODE=""
PARTITION="doppelbock"
PORT="22"  # 默认SSH端口

# Parse command line arguments
while getopts "a:w:p:o:" opt; do
    case $opt in
        a) CLUSTER="$OPTARG" ;;
        w) NODE="$OPTARG" ;;
        p) PARTITION="$OPTARG" ;;
        o) PORT="$OPTARG" ;;
        ?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
done

# SSH config file path
SSH_CONFIG="$HOME/.ssh/config"

case "$CLUSTER" in
    bluehive3)
        COMPUTE_HOST="bluehive_compute3"
        ;;
    bluehive|bhward)
        COMPUTE_HOST="${CLUSTER}_compute"
        ;;
    *)
        echo "Error: Unknown cluster $CLUSTER" >&2
        exit 1
        ;;
esac

if ! awk -v target="$COMPUTE_HOST" '
    /^Host[[:space:]]/ {
        n = split($0, parts, /[[:space:]]+/)
        for (i = 2; i <= n; i++) {
            if (parts[i] == target) {
                found = 1
            }
        }
    }
    END { exit(found ? 0 : 1) }
' "$SSH_CONFIG"; then
    echo "Error: Host $COMPUTE_HOST not found in $SSH_CONFIG" >&2
    exit 1
fi

update_host_value() {
    local host_alias="$1"
    local key="$2"
    local value="$3"
    local tmp_file
    tmp_file="$(mktemp "${SSH_CONFIG}.XXXXXX")"

    awk -v target="$host_alias" -v key="$key" -v value="$value" '
        function host_line_matches(    i, n, parts) {
            n = split($0, parts, /[[:space:]]+/)
            for (i = 2; i <= n; i++) {
                if (parts[i] == target) {
                    return 1
                }
            }
            return 0
        }
        function add_key_if_missing() {
            if (in_block && !updated) {
                print "\t" key " " value
                updated = 1
            }
        }
        /^Host[[:space:]]/ {
            add_key_if_missing()
            in_block = host_line_matches()
            updated = 0
            print
            next
        }
        in_block && $1 == key {
            print "\t" key " " value
            updated = 1
            next
        }
        { print }
        END {
            add_key_if_missing()
        }
    ' "$SSH_CONFIG" > "$tmp_file" && mv "$tmp_file" "$SSH_CONFIG"
}

# If node is specified, use it directly
if [ -n "$NODE" ]; then
    TARGET_NODE="$NODE"
# Otherwise use default logic based on partition
else
    if [ "$PARTITION" = "doppelbock" ]; then
        TARGET_NODE="bhg0061"
    elif [ "$PARTITION" = "dmi" ]; then
        TARGET_NODE="bhc0208"
    elif [ "$PARTITION" = "preempt" ]; then
        echo "Error: preempt partition requires a specific allocated node" >&2
        exit 1
    else
        echo "Error: Unknown partition $PARTITION" >&2
        exit 1
    fi
fi

update_host_value "$COMPUTE_HOST" "Hostname" "$TARGET_NODE"
update_host_value "$COMPUTE_HOST" "Port" "$PORT"

echo "Updated SSH config for $COMPUTE_HOST ($CLUSTER) with node: $TARGET_NODE and port: $PORT"
