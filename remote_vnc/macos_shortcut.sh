#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

print_usage() {
    cat <<'EOF'
Usage: remote-vnc-macos-shortcut ACTION

Translate a macOS Command-key action into the shortcut expected by the
currently focused Linux application.
EOF
}

[[ $# -eq 1 ]] || {
    print_usage >&2
    exit 2
}

action_name="$1"
xdotool_executable="$(command -v xdotool 2>/dev/null || true)"
[[ -x "${xdotool_executable}" ]] || {
    printf '[remote-vnc-shortcut] xdotool is unavailable.\n' >&2
    exit 1
}

active_window_id="$(
    "${xdotool_executable}" getactivewindow 2>/dev/null || true
)"
[[ "${active_window_id}" =~ ^[0-9]+$ ]] || exit 0

terminal_window_pattern='(alacritty|foot|gnome-terminal|kitty|konsole|'
terminal_window_pattern+='org.gnome.Terminal|org.wezfurlong.wezterm|terminator|'
terminal_window_pattern+='tilix|urxvt|uxterm|wezterm|xfce4-terminal|xterm)'
window_is_terminal=false
while IFS= read -r terminal_window_id; do
    if [[ "${terminal_window_id}" == "${active_window_id}" ]]; then
        window_is_terminal=true
        break
    fi
done < <(
    "${xdotool_executable}" search --onlyvisible --class \
        "${terminal_window_pattern}" 2>/dev/null || true
)

gui_key_sequence=""
terminal_key_sequence=""
case "${action_name}" in
    copy)
        gui_key_sequence='ctrl+c'
        terminal_key_sequence='ctrl+shift+c'
        ;;
    paste)
        gui_key_sequence='ctrl+v'
        terminal_key_sequence='ctrl+shift+v'
        ;;
    select-all)
        gui_key_sequence='ctrl+a'
        terminal_key_sequence='ctrl+shift+a'
        ;;
    find)
        gui_key_sequence='ctrl+f'
        terminal_key_sequence='ctrl+shift+f'
        ;;
    new-window)
        gui_key_sequence='ctrl+n'
        terminal_key_sequence='ctrl+shift+n'
        ;;
    new-tab)
        gui_key_sequence='ctrl+t'
        terminal_key_sequence='ctrl+shift+t'
        ;;
    close)
        gui_key_sequence='ctrl+w'
        terminal_key_sequence='ctrl+shift+w'
        ;;
    cut)
        gui_key_sequence='ctrl+x'
        ;;
    undo)
        gui_key_sequence='ctrl+z'
        ;;
    redo)
        gui_key_sequence='ctrl+shift+z'
        ;;
    save)
        gui_key_sequence='ctrl+s'
        ;;
    open)
        gui_key_sequence='ctrl+o'
        ;;
    reload)
        gui_key_sequence='ctrl+r'
        ;;
    location)
        gui_key_sequence='ctrl+l'
        ;;
    print)
        gui_key_sequence='ctrl+p'
        ;;
    *)
        printf '[remote-vnc-shortcut] Unknown action: %s\n' \
            "${action_name}" >&2
        print_usage >&2
        exit 2
        ;;
esac

key_sequence="${gui_key_sequence}"
if [[ "${window_is_terminal}" == "true" ]]; then
    key_sequence="${terminal_key_sequence}"
fi

# Some GUI editing shortcuts would invoke shell control characters in a
# terminal. An empty terminal mapping deliberately leaves those actions idle.
[[ -n "${key_sequence}" ]] || exit 0

"${xdotool_executable}" key --clearmodifiers --delay 12 "${key_sequence}"
