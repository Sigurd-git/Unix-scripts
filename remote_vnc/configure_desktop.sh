#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

action="${1:-}"
force_apply="${2:-}"
profile_version="20260904.2"
theme_commit="e39f6341fdcdf02826d3daab68faf4204669edf3"
theme_archive_sha256="50ca872c44d28acfa9d43aa337981520ccc19b807dfc6b5293c7d8d9fe0f3a93"
theme_archive_name="WhiteSur-Light-solid-${theme_commit}.tar.xz"
theme_download_url="https://raw.githubusercontent.com/vinceliuice/WhiteSur-gtk-theme/${theme_commit}/release/WhiteSur-Light-solid.tar.xz"
theme_name="RemoteVNC-WhiteSur-Light-${theme_commit:0:8}"
theme_parent_directory="${HOME:?HOME is required}/.themes"
theme_directory="${theme_parent_directory}/${theme_name}"
cache_directory="${XDG_CACHE_HOME:-${HOME}/.cache}/remote-vnc"
theme_cache_directory="${cache_directory}/themes"
theme_archive="${theme_cache_directory}/${theme_archive_name}"
profile_state_file="${cache_directory}/desktop-profile.env"
profile_marker_file="${cache_directory}/desktop-profile-version"
profile_log_file="${cache_directory}/desktop-profile.log"
macos_shortcut_launcher="${HOME}/.local/bin/remote-vnc-macos-shortcut"
macos_shortcuts_status="UNAVAILABLE"
wallpaper_file="${XDG_DATA_HOME:-${HOME}/.local/share}/backgrounds/bluehive-aurora.svg"
temporary_directory=""

mkdir -p "${cache_directory}" "${theme_cache_directory}"
chmod 700 "${cache_directory}" "${theme_cache_directory}"

log_message() {
    printf '[remote-vnc-desktop] %s\n' "$*" | tee -a "${profile_log_file}" >&2
}

write_profile_state() {
    local status_value="$1"
    local active_theme="$2"
    local temporary_state_file="${profile_state_file}.tmp.$$"

    {
        printf 'STATUS=%s\n' "${status_value}"
        printf 'PROFILE_VERSION=%s\n' "${profile_version}"
        printf 'THEME=%s\n' "${active_theme}"
        printf 'MACOS_SHORTCUTS=%s\n' "${macos_shortcuts_status}"
        printf 'DISPLAY=%s\n' "${DISPLAY:-}"
        printf 'JOB_ID=%s\n' "${SLURM_JOB_ID:-}"
        printf 'UPDATED_AT=%s\n' "$(date --iso-8601=seconds 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${temporary_state_file}"
    chmod 600 "${temporary_state_file}"
    mv "${temporary_state_file}" "${profile_state_file}"
}

cleanup() {
    if [[ -n "${temporary_directory}" && -d "${temporary_directory}" ]]; then
        rm -rf -- "${temporary_directory}"
    fi
}
trap cleanup EXIT

theme_is_valid() {
    [[ -s "${theme_directory}/index.theme" &&
       -s "${theme_directory}/gtk-3.0/gtk.css" &&
       -s "${theme_directory}/xfwm4/themerc" ]]
}

archive_is_valid() {
    local actual_sha256

    [[ -s "${theme_archive}" ]] || return 1
    actual_sha256="$(sha256sum "${theme_archive}" | awk '{ print $1; exit }')"
    [[ "${actual_sha256}" == "${theme_archive_sha256}" ]]
}

prepare_theme() {
    local downloaded_archive
    local extracted_theme_directory

    if theme_is_valid; then
        log_message "Theme is ready: ${theme_directory}"
        return 0
    fi

    if ! archive_is_valid; then
        downloaded_archive="${theme_archive}.tmp.$$"
        rm -f -- "${downloaded_archive}"
        log_message "Downloading the pinned WhiteSur theme..."
        if ! curl \
            --fail --location --silent --show-error \
            --retry 3 --connect-timeout 15 --max-time 180 \
            --output "${downloaded_archive}" \
            "${theme_download_url}"; then
            rm -f -- "${downloaded_archive}"
            return 1
        fi
        [[ "$(sha256sum "${downloaded_archive}" | awk '{ print $1; exit }')" == \
           "${theme_archive_sha256}" ]] || {
            log_message "Downloaded theme checksum did not match."
            rm -f -- "${downloaded_archive}"
            return 1
        }
        mv "${downloaded_archive}" "${theme_archive}"
        chmod 600 "${theme_archive}"
    fi

    mkdir -p "${theme_parent_directory}"
    chmod 700 "${theme_parent_directory}"
    temporary_directory="$(
        mktemp -d "${theme_parent_directory}/.remote-vnc-theme.XXXXXX"
    )"
    tar -xJf "${theme_archive}" -C "${temporary_directory}"
    extracted_theme_directory="${temporary_directory}/WhiteSur-Light-solid"
    [[ -s "${extracted_theme_directory}/gtk-3.0/gtk.css" &&
       -s "${extracted_theme_directory}/xfwm4/themerc" ]] || {
        log_message "Extracted theme is incomplete."
        return 1
    }

    if [[ -e "${theme_directory}" ]]; then
        log_message "Theme path already exists but is incomplete: ${theme_directory}"
        return 1
    fi
    mv "${extracted_theme_directory}" "${theme_directory}"
    rmdir "${temporary_directory}"
    temporary_directory=""
    log_message "Installed theme: ${theme_directory}"
}

wait_for_xfconf() {
    local attempt_number

    [[ -n "${DISPLAY:-}" ]] || return 1
    command -v xfconf-query >/dev/null 2>&1 || return 1
    for ((attempt_number = 1; attempt_number <= 45; attempt_number++)); do
        if xfconf-query -c xsettings -l >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

property_exists() {
    local channel_name="$1"
    local property_name="$2"

    xfconf-query -c "${channel_name}" -p "${property_name}" \
        >/dev/null 2>&1
}

set_property() {
    local channel_name="$1"
    local property_name="$2"
    local property_type="$3"
    local property_value="$4"

    if property_exists "${channel_name}" "${property_name}"; then
        xfconf-query -c "${channel_name}" -p "${property_name}" \
            -s "${property_value}" >/dev/null
    else
        xfconf-query -c "${channel_name}" -p "${property_name}" \
            -n -t "${property_type}" -s "${property_value}" >/dev/null
    fi
}

set_existing_property() {
    local channel_name="$1"
    local property_name="$2"
    local property_value="$3"

    property_exists "${channel_name}" "${property_name}" || return 0
    xfconf-query -c "${channel_name}" -p "${property_name}" \
        -s "${property_value}" >/dev/null
}

remove_property() {
    local channel_name="$1"
    local property_name="$2"

    property_exists "${channel_name}" "${property_name}" || return 0
    xfconf-query -c "${channel_name}" -p "${property_name}" -r >/dev/null
}

configure_wallpaper() {
    local found_image_property=false
    local image_property
    local property_prefix
    local workspace_number

    [[ -s "${wallpaper_file}" ]] || return 0
    while IFS= read -r image_property; do
        [[ "${image_property}" == */last-image ]] || continue
        found_image_property=true
        property_prefix="${image_property%/last-image}"
        set_property \
            xfce4-desktop "${property_prefix}/image-style" int 5
        set_property \
            xfce4-desktop "${property_prefix}/color-style" int 0
        set_property \
            xfce4-desktop "${image_property}" string "${wallpaper_file}"
    done < <(xfconf-query -c xfce4-desktop -l 2>/dev/null || true)

    if [[ "${found_image_property}" != "true" ]]; then
        for workspace_number in 0 1 2 3; do
            property_prefix="/backdrop/screen0/monitorVNC-0/workspace${workspace_number}"
            set_property \
                xfce4-desktop "${property_prefix}/image-style" int 5
            set_property \
                xfce4-desktop "${property_prefix}/color-style" int 0
            set_property \
                xfce4-desktop "${property_prefix}/last-image" string \
                "${wallpaper_file}"
        done
    fi
}

configure_application_shortcuts() {
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>space' string \
        'xfce4-appfinder --collapsed'
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>Return' string \
        'exo-open --launch TerminalEmulator'
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>e' string thunar
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>comma' string xfce4-settings-manager
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Shift><Super>3' string 'xfce4-screenshooter -f'
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Shift><Super>4' string 'xfce4-screenshooter -r'
}

configure_macos_application_shortcuts() {
    local shortcut_name

    if [[ ! -x "${macos_shortcut_launcher}" ]] ||
       ! command -v xdotool >/dev/null 2>&1; then
        for shortcut_name in \
            '<Super>a' '<Super>c' '<Super>f' '<Super>l' '<Super>n' \
            '<Super>o' '<Super>p' '<Super>r' '<Super>s' '<Super>t' \
            '<Super>v' '<Super>w' '<Super>x' '<Super>z' \
            '<Shift><Super>z'; do
            remove_property xfce4-keyboard-shortcuts \
                "/commands/custom/${shortcut_name}"
        done
        macos_shortcuts_status="UNAVAILABLE"
        log_message "macOS application shortcuts need xdotool and ${macos_shortcut_launcher}."
        return 0
    fi

    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>a' string \
        "${macos_shortcut_launcher} select-all"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>c' string \
        "${macos_shortcut_launcher} copy"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>f' string \
        "${macos_shortcut_launcher} find"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>l' string \
        "${macos_shortcut_launcher} location"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>n' string \
        "${macos_shortcut_launcher} new-window"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>o' string \
        "${macos_shortcut_launcher} open"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>p' string \
        "${macos_shortcut_launcher} print"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>r' string \
        "${macos_shortcut_launcher} reload"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>s' string \
        "${macos_shortcut_launcher} save"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>t' string \
        "${macos_shortcut_launcher} new-tab"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>v' string \
        "${macos_shortcut_launcher} paste"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>w' string \
        "${macos_shortcut_launcher} close"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>x' string \
        "${macos_shortcut_launcher} cut"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Super>z' string \
        "${macos_shortcut_launcher} undo"
    set_property xfce4-keyboard-shortcuts \
        '/commands/custom/<Shift><Super>z' string \
        "${macos_shortcut_launcher} redo"
    macos_shortcuts_status="READY"
}

configure_window_shortcuts() {
    set_property xfce4-keyboard-shortcuts \
        '/xfwm4/custom/<Super>Tab' string switch_window_key
    set_property xfce4-keyboard-shortcuts \
        '/xfwm4/custom/<Shift><Super>Tab' string cycle_reverse_windows_key
    set_property xfce4-keyboard-shortcuts \
        '/xfwm4/custom/<Super>m' string hide_window_key
    set_property xfce4-keyboard-shortcuts \
        '/xfwm4/custom/<Super>Up' string maximize_window_key
    set_property xfce4-keyboard-shortcuts \
        '/xfwm4/custom/<Super>Left' string tile_left_key
    set_property xfce4-keyboard-shortcuts \
        '/xfwm4/custom/<Super>Right' string tile_right_key
    set_property xfce4-keyboard-shortcuts \
        '/xfwm4/custom/<Super>grave' string cycle_windows_key
}

apply_profile() {
    local active_theme="Greybird"
    local active_window_theme="Default"
    local expected_marker
    local existing_marker=""

    if theme_is_valid; then
        active_theme="${theme_name}"
        active_window_theme="${theme_name}"
    fi
    if [[ -x "${macos_shortcut_launcher}" ]] &&
       command -v xdotool >/dev/null 2>&1; then
        macos_shortcuts_status="READY"
    fi
    expected_marker="${profile_version}:${active_theme}:${active_window_theme}:${macos_shortcuts_status}"
    if [[ -s "${profile_marker_file}" ]]; then
        existing_marker="$(head -n 1 "${profile_marker_file}")"
    fi

    if [[ "${force_apply}" != "--force" &&
          "${existing_marker}" == "${expected_marker}" ]]; then
        write_profile_state "READY_REUSED" "${active_theme}"
        log_message "Desktop profile is already applied (${active_theme})."
        return 0
    fi

    wait_for_xfconf || {
        write_profile_state "FAILED_XFCONF" "${active_theme}"
        log_message "XFCE settings service did not become ready."
        return 1
    }

    set_property xsettings /Net/ThemeName string "${active_theme}"
    set_property xsettings /Net/IconThemeName string elementary-xfce
    set_property xsettings /Gtk/FontName string 'Noto Sans 11'
    set_property xsettings /Gtk/MonospaceFontName string 'Noto Sans Mono 11'
    set_property xsettings /Gtk/DecorationLayout string \
        'close,minimize,maximize:'
    set_property xsettings /Gtk/CursorThemeName string Adwaita
    set_property xsettings /Gtk/CursorThemeSize int 24
    set_property xsettings /Xft/DPI int 110
    set_property xsettings /Xft/Antialias int 1
    set_property xsettings /Xft/Hinting int 1
    set_property xsettings /Xft/HintStyle string hintslight
    set_property xsettings /Xft/RGBA string rgb

    set_property xfwm4 /general/theme string "${active_window_theme}"
    set_property xfwm4 /general/button_layout string 'CHM|'
    set_property xfwm4 /general/title_alignment string center
    set_property xfwm4 /general/title_font string 'Noto Sans Bold 10'
    set_property xfwm4 /general/use_compositing bool true
    set_property xfwm4 /general/show_dock_shadow bool true

    set_existing_property xfce4-panel /panels/dark-mode false
    set_existing_property xfce4-panel /panels/panel-1/size 32
    set_existing_property xfce4-panel /panels/panel-1/icon-size 20
    set_existing_property xfce4-panel /panels/panel-2/size 64
    if property_exists xfce4-panel /panels/panel-2/size; then
        set_property xfce4-panel /panels/panel-2/icon-size int 48
    fi
    set_existing_property xfce4-panel /panels/panel-2/autohide-behavior 1

    configure_wallpaper
    configure_application_shortcuts
    configure_macos_application_shortcuts
    configure_window_shortcuts

    printf '%s\n' "${expected_marker}" > "${profile_marker_file}"
    chmod 600 "${profile_marker_file}"
    write_profile_state "READY" "${active_theme}"
    log_message "Applied desktop profile (${active_theme})."
}

case "${action}" in
    prepare)
        if prepare_theme; then
            write_profile_state "PREPARED" "${theme_name}"
        else
            write_profile_state "PREPARE_FAILED" "Greybird"
            log_message "WhiteSur preparation failed; XFCE will use Greybird."
            exit 1
        fi
        ;;
    apply)
        [[ -z "${force_apply}" || "${force_apply}" == "--force" ]] || {
            printf 'Usage: %s apply [--force]\n' "$0" >&2
            exit 2
        }
        apply_profile
        ;;
    status)
        [[ -s "${profile_state_file}" ]] || {
            printf 'Desktop profile has not run yet.\n' >&2
            exit 1
        }
        cat "${profile_state_file}"
        ;;
    *)
        printf 'Usage: %s {prepare|apply [--force]|status}\n' "$0" >&2
        exit 2
        ;;
esac
