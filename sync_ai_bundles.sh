#!/bin/bash

set -euo pipefail

readonly MUTAGEN_BIN="/opt/homebrew/bin/mutagen"
readonly SSH_BIN="/usr/bin/ssh"
readonly REMOTE_HOST="blhc3"
readonly REMOTE_BUNDLE_ROOT="/scratch/snormanh_lab/shared/code/toydata/tmp"
readonly LOCAL_BUNDLE_ROOT="/Users/gliao2/Downloads"
readonly MANAGED_SESSION_LABEL="paper-ai-bundle-sync"

log_message() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

if [[ ! -x "$MUTAGEN_BIN" ]]; then
    log_message "Mutagen not found at $MUTAGEN_BIN"
    exit 1
fi

if ! remote_bundle_names="$($SSH_BIN \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    "$REMOTE_HOST" \
    "find '$REMOTE_BUNDLE_ROOT' -mindepth 2 -maxdepth 3 -type f -name '*.ai' -printf '%P\\n' 2>/dev/null" \
    | /usr/bin/awk -F/ 'NF >= 2 {print $1}' \
    | /usr/bin/sort -u)"; then
    log_message "Cannot inspect $REMOTE_HOST:$REMOTE_BUNDLE_ROOT; existing Mutagen sessions were left unchanged"
    exit 0
fi

while IFS= read -r bundle_name; do
    [[ -n "$bundle_name" ]] || continue

    case "$bundle_name" in
        final_paper_ai_linked|.*)
            continue
            ;;
    esac

    bundle_slug="$(printf '%s' "$bundle_name" \
        | /usr/bin/tr '[:upper:]' '[:lower:]' \
        | /usr/bin/tr -cs '[:alnum:]' '-' \
        | /usr/bin/sed 's/^-//; s/-$//')"
    [[ -n "$bundle_slug" ]] || continue

    bundle_hash="$(printf '%s' "$bundle_name" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-10)"
    session_name="paper-ai-${bundle_slug:0:36}-${bundle_hash}"
    local_bundle_path="$LOCAL_BUNDLE_ROOT/$bundle_name"
    remote_bundle_path="$REMOTE_BUNDLE_ROOT/$bundle_name"

    if "$MUTAGEN_BIN" sync list "$session_name" >/dev/null 2>&1; then
        continue
    fi

    /bin/mkdir -p "$local_bundle_path"
    log_message "Creating $session_name for $bundle_name"

    "$MUTAGEN_BIN" sync create \
        --name="$session_name" \
        --label="managed-by=$MANAGED_SESSION_LABEL" \
        --mode=two-way-safe \
        --ignore=.DS_Store \
        --ignore='~*.tmp' \
        "$local_bundle_path" \
        "$REMOTE_HOST:$remote_bundle_path"
done <<< "$remote_bundle_names"
