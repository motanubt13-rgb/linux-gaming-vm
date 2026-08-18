#!/usr/bin/env bash
# ==============================================================================
# Linux-Gaming-VM
# Version 0.4
#
# Designed for Vast.ai KVM virtual machines running Ubuntu with KDE Plasma.
# ==============================================================================

set -u
set -o pipefail

SCRIPT_NAME="Linux-Gaming-VM"
SCRIPT_VERSION="V0.4"
SCRIPT_BUILD="2026-08-18-r6"

LOG_DIR="/var/lib/.linux-gaming-vm"
LOG_FILE="${LOG_DIR}/linux-gaming-vm.log"
SUPPORT_LOG=""

ERRORS=0
WARNINGS=0

DESKTOP_USER=""
DESKTOP_GROUP=""
DESKTOP_HOME=""
DESKTOP_UID=""
DISPLAY_VALUE="${DISPLAY:-:0}"
XAUTHORITY_VALUE=""

TAILSCALE_IP="Not connected"
SUNSHINE_URL="Unavailable"
NVIDIA_REBOOT_MARKER="${LOG_DIR}/nvidia-reboot.pending"
APT_REFRESH_MARKER="${LOG_DIR}/apt-index-refreshed"
APT_REFRESH_MAX_AGE=3600
APT_INDEX_REFRESHED=0
RESOLUTION="Keep current"
REFRESH_RATE="Keep current"

declare -A STATUS

if [[ -t 1 ]]; then
    RESET=$'\033[0m'
    BLUE=$'\033[1;34m'
    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
else
    RESET=""
    BLUE=""
    GREEN=""
    YELLOW=""
    RED=""
fi

# ==============================================================================
# Logging and terminal output
# ==============================================================================

init_log() {
    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    {
        echo
        echo "=============================================================================="
        printf '%s [INFO] %s %s started\n' "$(date '+%F %T')" "$SCRIPT_NAME" "$SCRIPT_VERSION"
        echo "=============================================================================="
    } >>"$LOG_FILE"
}

write_log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE"
}

info() {
    printf '%s[INFO]%s  %s\n' "$BLUE" "$RESET" "$*"
    write_log INFO "$*"
}

ok() {
    printf '%s[ OK ]%s  %s\n' "$GREEN" "$RESET" "$*"
    write_log OK "$*"
}

warn() {
    printf '%s[WARN]%s  %s\n' "$YELLOW" "$RESET" "$*"
    write_log WARN "$*"
    ((WARNINGS++)) || true
}

error() {
    printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*"
    write_log ERROR "$*"
    ((ERRORS++)) || true
}

run_long() {
    local description="$1"
    shift

    local temp_file
    local pid rc
    local spinner='|/-\'
    local spin_index=0
    local percent=""

    temp_file="$(mktemp)"
    write_log COMMAND "$*"

    "$@" >"$temp_file" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        percent="$(
            tr '\r' '\n' <"$temp_file" 2>/dev/null \
            | grep -oE '(^|[^0-9])[0-9]{1,3}%' \
            | tail -n1 \
            | grep -oE '[0-9]{1,3}' || true
        )"

        if [[ -n "$percent" ]] && (( percent >= 0 && percent <= 100 )); then
            printf '\r\033[K%s[INFO]%s  %-46s %3d%%' \
                "$BLUE" "$RESET" "${description}..." "$percent"
        else
            printf '\r\033[K%s[INFO]%s  %-46s [%s]' \
                "$BLUE" "$RESET" "${description}..." "${spinner:spin_index%4:1}"
            ((spin_index++)) || true
        fi

        sleep 0.5
    done

    wait "$pid"
    rc=$?

    cat "$temp_file" >>"$LOG_FILE"
    rm -f "$temp_file"

    printf '\r\033[K'

    if (( rc == 0 )); then
        printf '%s[ OK ]%s  %-46s 100%%\n' \
            "$GREEN" "$RESET" "${description}..."
        write_log OK "$description completed"
        return 0
    fi

    printf '%s[ERROR]%s %-46s failed\n' \
        "$RED" "$RESET" "${description}..."
    write_log ERROR "$description failed with exit code $rc"
    ((ERRORS++)) || true
    return "$rc"
}

run_user() {
    sudo -u "$DESKTOP_USER" env \
        HOME="$DESKTOP_HOME" \
        USER="$DESKTOP_USER" \
        LOGNAME="$DESKTOP_USER" \
        DISPLAY="$DISPLAY_VALUE" \
        XAUTHORITY="$XAUTHORITY_VALUE" \
        XDG_RUNTIME_DIR="/run/user/${DESKTOP_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
        XDG_DATA_DIRS="/var/lib/flatpak/exports/share:${DESKTOP_HOME}/.local/share/flatpak/exports/share:/usr/local/share:/usr/share" \
        "$@"
}

# ==============================================================================
# Banner and environment detection
# ==============================================================================

banner() {
    clear 2>/dev/null || true
    cat <<'EOF'
=========================================
Linux-Gaming-VM
Version V0.4
=========================================

This script is optimized for Vast.ai KVM virtual machines.
Missing components will be installed, and gaming optimizations applied.

Press ENTER to continue...
EOF

    [[ -t 0 ]] && read -r || true
}

self_check_script() {
    local script_path
    local duplicate_functions
    local required_function
    local failures=0

    script_path="${BASH_SOURCE[0]}"

    if ! bash -n "$script_path" >/dev/null 2>&1; then
        echo "[SELF-CHECK ERROR] Bash syntax validation failed."
        ((failures++)) || true
    fi

    duplicate_functions="$({
        sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)\(\)[[:space:]]*\{.*/\1/p' "$script_path" \
            | sort \
            | uniq -d
    } 2>/dev/null || true)"

    if [[ -n "$duplicate_functions" ]]; then
        echo "[SELF-CHECK ERROR] Duplicate function definition(s):"
        printf '%s\n' "$duplicate_functions"
        ((failures++)) || true
    fi

    for required_function in \
        detect_environment \
        disable_automatic_updates \
        remove_selkies_webrtc \
        update_nvidia_driver_with_reboot \
        verify_system \
        wait_for_desktop_session \
        install_and_update_applications \
        configure_audio \
        configure_tailscale \
        configure_sunshine \
        configure_host_optimizations \
        configure_desktop \
        configure_mouse_acceleration \
        configure_display \
        summary; do

        if ! grep -qE "^${required_function}\\(\\)[[:space:]]*\\{" "$script_path"; then
            echo "[SELF-CHECK ERROR] Missing function: $required_function"
            ((failures++)) || true
        fi
    done

    if (( failures > 0 )); then
        echo "SELF-CHECK FAILED ($failures problem(s))"
        return 1
    fi

    echo "SELF-CHECK OK - ${SCRIPT_NAME} ${SCRIPT_VERSION} (${SCRIPT_BUILD})"
    return 0
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script requires administrator privileges."
        echo
        echo "Run it with:"
        echo "  sudo bash $0"
        exit 1
    fi
}

detect_environment() {
    if [[ ! -r /etc/os-release ]]; then
        error "Operating system information could not be read."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        error "This script currently supports Ubuntu only."
        exit 1
    fi

    STATUS["Operating system"]="${PRETTY_NAME:-Ubuntu}"

    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        DESKTOP_USER="$SUDO_USER"
    else
        DESKTOP_USER="$(
            loginctl list-sessions --no-legend 2>/dev/null \
            | awk '$3 != "root" {print $3; exit}'
        )"

        if [[ -z "$DESKTOP_USER" ]]; then
            DESKTOP_USER="$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd)"
        fi
    fi

    if [[ -z "$DESKTOP_USER" ]] || ! id "$DESKTOP_USER" >/dev/null 2>&1; then
        error "The desktop user could not be detected."
        exit 1
    fi

    DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
    DESKTOP_UID="$(id -u "$DESKTOP_USER")"
    DESKTOP_GROUP="$(id -gn "$DESKTOP_USER")"

    XAUTHORITY_VALUE="${DESKTOP_HOME}/.Xauthority"
    if [[ ! -f "$XAUTHORITY_VALUE" ]]; then
        local found_xauth
        found_xauth="$(find "/run/user/${DESKTOP_UID}" /tmp /var/run -maxdepth 3 -name "*auth*" -o -name ".Xauthority" 2>/dev/null | head -n1 || true)"
        [[ -n "$found_xauth" ]] && XAUTHORITY_VALUE="$found_xauth"
    fi

    SUPPORT_LOG="${DESKTOP_HOME}/.local/share/.linux-gaming-vm/linux-gaming-vm.log"

    loginctl enable-linger "$DESKTOP_USER" >>"$LOG_FILE" 2>&1 || true

    STATUS["Desktop user"]="$DESKTOP_USER"
    STATUS["Desktop group"]="$DESKTOP_GROUP"

    ok "Desktop user detected: $DESKTOP_USER (Lingering enabled)"
    write_log INFO "Desktop group detected: $DESKTOP_GROUP"
}

disable_automatic_updates() {
    echo
    echo "========================================="
    echo "Prepare Package Manager"
    echo "========================================="

    info "Disabling Ubuntu automatic updates permanently"

    systemctl stop apt-daily.timer apt-daily-upgrade.timer >>"$LOG_FILE" 2>&1 || true
    systemctl disable apt-daily.timer apt-daily-upgrade.timer >>"$LOG_FILE" 2>&1 || true
    systemctl mask apt-daily.timer apt-daily-upgrade.timer >>"$LOG_FILE" 2>&1 || true

    systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >>"$LOG_FILE" 2>&1 || true
    systemctl disable unattended-upgrades.service >>"$LOG_FILE" 2>&1 || true
    systemctl mask apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >>"$LOG_FILE" 2>&1 || true

    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

    pkill -TERM -f '/usr/bin/unattended-upgrade|/usr/lib/apt/apt.systemd.daily' >>"$LOG_FILE" 2>&1 || true
    sleep 2

    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do

        if (( waited >= 60 )); then
            error "Package manager locks were not released"
            return 1
        fi
        sleep 1
        ((waited++)) || true
    done

    env DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
    STATUS["Automatic updates"]="Disabled"
    ok "Ubuntu automatic updates disabled"
}

wait_apt() {
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do

        if (( waited == 0 )); then
            warn "APT is busy. Waiting for lock release..."
        fi
        if (( waited >= 900 )); then
            error "APT remained locked for more than 15 minutes."
            return 1
        fi
        sleep 3
        ((waited+=3))
    done
}

apt_indexes_are_fresh() {
    local now=""
    local refreshed_at=""
    local age=""

    if (( APT_INDEX_REFRESHED == 1 )); then
        return 0
    fi

    [[ -f "$APT_REFRESH_MARKER" ]] || return 1
    now="$(date +%s)"
    refreshed_at="$(stat -c %Y "$APT_REFRESH_MARKER" 2>/dev/null || true)"
    [[ "$refreshed_at" =~ ^[0-9]+$ ]] || return 1

    age=$((now - refreshed_at))
    if (( age >= 0 && age <= APT_REFRESH_MAX_AGE )); then
        APT_INDEX_REFRESHED=1
        return 0
    fi
    return 1
}

refresh_apt_indexes() {
    local description="${1:-Updating APT package indexes}"

    if apt_indexes_are_fresh; then
        ok "APT package indexes were refreshed recently"
        return 0
    fi

    wait_apt || return 1

    if ! run_long "$description" apt-get update; then
        return 1
    fi

    touch "$APT_REFRESH_MARKER"
    chmod 600 "$APT_REFRESH_MARKER"
    APT_INDEX_REFRESHED=1
    return 0
}

installed_version() {
    local package="$1"
    dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true
}

candidate_version() {
    local package="$1"
    apt-cache policy "$package" 2>/dev/null \
        | awk '/Candidate:/ {print $2; exit}'
}

version_is_newer() {
    local candidate="$1"
    local installed="$2"

    [[ -n "$candidate" && -n "$installed" ]] || return 1
    [[ "$candidate" != "(none)" ]] || return 1

    dpkg --compare-versions "$candidate" gt "$installed"
}

apt_install_or_update() {
    local package="$1"
    local command_name="${2:-$1}"
    local label="${3:-$package}"

    local installed=""
    local candidate=""

    installed="$(installed_version "$package")"
    candidate="$(candidate_version "$package")"

    if [[ -z "$installed" ]]; then
        wait_apt || return 1
        if run_long "Installing $label" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
            STATUS["$label"]="Installed"
            return 0
        fi
        STATUS["$label"]="Install failed"
        return 1
    fi

    if version_is_newer "$candidate" "$installed"; then
        wait_apt || return 1
        if run_long "Updating $label" env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "$package"; then
            STATUS["$label"]="Updated"
            return 0
        fi
        STATUS["$label"]="Update failed"
        return 1
    fi

    STATUS["$label"]="Already latest"
    ok "$label is already latest"
    return 0
}

set_batch_package_status() {
    local label="$1"
    local package="$2"
    local command_name="$3"
    local before_version="${4:-}"
    local after_version=""

    after_version="$(installed_version "$package")"

    if [[ -z "$after_version" ]]; then
        STATUS["$label"]="Install or update failed"
        return 1
    fi

    if [[ -z "$before_version" ]]; then
        STATUS["$label"]="Installed"
    elif dpkg --compare-versions "$after_version" gt "$before_version"; then
        STATUS["$label"]="Updated"
    else
        STATUS["$label"]="Already latest"
    fi

    ok "$label: ${STATUS[$label]}"
}

# ==============================================================================
# Flatpak & KDE Start Menu / Desktop Integration (with Live Sync Service)
# ==============================================================================

find_desktop_file() {
    local pattern
    local result

    for pattern in "$@"; do
        result="$(
            find \
                /usr/share/applications \
                /var/lib/flatpak/exports/share/applications \
                "${DESKTOP_HOME}/.local/share/applications" \
                -maxdepth 2 \
                -type f \
                -iname "$pattern" \
                2>/dev/null \
                | head -n1
        )"

        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    done

    return 1
}

create_shortcut() {
    local label="$1"
    shift

    local source_file
    local destination

    source_file="$(find_desktop_file "$@" || true)"
    destination="${DESKTOP_HOME}/Desktop/${label}.desktop"

    if [[ -n "$source_file" && -f "$source_file" ]]; then
        cp "$source_file" "$destination"
    else
        case "$label" in
            Steam)
                cat >"$destination" <<'EOF_FALLBACK'
[Desktop Entry]
Name=Steam
Comment=Application for managing and playing games
Exec=/usr/games/steam %U
Icon=steam
Terminal=false
Type=Application
Categories=Network;FileTransfer;Game;
EOF_FALLBACK
                ;;
            "Google Chrome")
                cat >"$destination" <<'EOF_FALLBACK'
[Desktop Entry]
Name=Google Chrome
Comment=Access the Internet
Exec=/usr/bin/google-chrome-stable %U
Icon=google-chrome
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF_FALLBACK
                ;;
            *)
                write_log WARN "Desktop shortcut source not found for $label"
                return 1
                ;;
        esac
    fi

    chown "$DESKTOP_USER:$DESKTOP_GROUP" "$destination" || true
    chmod +x "$destination" || true
    run_user gio set "$destination" metadata::trusted true 2>/dev/null || true
    ok "$label desktop shortcut created"
}

setup_flatpak_desktop_sync_service() {
    # 1. Utilitar de sincronizare permanentă a scurtăturilor Desktop pentru Flatpak / Discover
    cat >/usr/local/bin/flatpak-desktop-sync.sh <<'EOF_SYNC_TOOL'
#!/usr/bin/env bash
DESKTOP_DIR="${HOME}/Desktop"
mkdir -p "$DESKTOP_DIR"

sync_shortcuts() {
    local search_dirs=(
        "/var/lib/flatpak/exports/share/applications"
        "${HOME}/.local/share/flatpak/exports/share/applications"
    )
    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        find "$dir" -maxdepth 1 -name '*.desktop' 2>/dev/null | while read -r dfile; do
            local base
            base="$(basename "$dfile")"
            if [[ ! -f "${DESKTOP_DIR}/${base}" ]]; then
                cp "$dfile" "${DESKTOP_DIR}/${base}"
                chmod +x "${DESKTOP_DIR}/${base}"
                gio set "${DESKTOP_DIR}/${base}" metadata::trusted true 2>/dev/null || true
            fi
        done
    done

    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    elif command -v kbuildsycoca5 >/dev/null 2>&1; then
        kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
    fi
}

sync_shortcuts

if command -v inotifywait >/dev/null 2>&1; then
    while true; do
        mkdir -p "${HOME}/.local/share/flatpak/exports/share/applications" 2>/dev/null || true
        inotifywait -q -e create,moved_to \
            /var/lib/flatpak/exports/share/applications \
            "${HOME}/.local/share/flatpak/exports/share/applications" 2>/dev/null || sleep 5
        sleep 2
        sync_shortcuts
    done
else
    while true; do
        sleep 10
        sync_shortcuts
    done
fi
EOF_SYNC_TOOL
    chmod 755 /usr/local/bin/flatpak-desktop-sync.sh

    # 2. Serviciu Systemd de utilizator pentru auto-creare scurtături Discover
    local systemd_user_dir="${DESKTOP_HOME}/.config/systemd/user"
    mkdir -p "$systemd_user_dir"
    cat >"${systemd_user_dir}/flatpak-desktop-sync.service" <<'EOF_SERVICE'
[Unit]
Description=Auto-sync Flatpak/Discover apps to Desktop
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/flatpak-desktop-sync.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF_SERVICE

    chown -R "$DESKTOP_USER:$DESKTOP_GROUP" "${DESKTOP_HOME}/.config/systemd"
    run_user systemctl --user daemon-reload >>"$LOG_FILE" 2>&1 || true
    run_user systemctl --user enable --now flatpak-desktop-sync.service >>"$LOG_FILE" 2>&1 || true
}

ensure_flatpak() {
    local flatpak_packages=(
        flatpak
        plasma-discover
        plasma-discover-backend-flatpak
        xdg-desktop-portal
        xdg-desktop-portal-kde
        xdg-utils
        desktop-file-utils
        inotify-tools
    )
    local missing_packages=()
    local package=""

    for package in "${flatpak_packages[@]}"; do
        dpkg -s "$package" >/dev/null 2>&1 || missing_packages+=("$package")
    done

    if (( ${#missing_packages[@]} > 0 )); then
        wait_apt || return 1
        if ! run_long "Installing Flatpak & KDE integration" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"; then
            STATUS["Flatpak"]="Install failed"
            return 1
        fi
    fi

    if ! flatpak remotes --system --columns=name 2>/dev/null | grep -qx flathub; then
        run_long "Configuring Flathub" \
            flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
    fi

    cat >/etc/profile.d/flatpak.sh <<'EOF'
export XDG_DATA_DIRS="/var/lib/flatpak/exports/share:${HOME}/.local/share/flatpak/exports/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
EOF
    chmod 644 /etc/profile.d/flatpak.sh

    mkdir -p "${DESKTOP_HOME}/.config/environment.d"
    cat >"${DESKTOP_HOME}/.config/environment.d/flatpak.conf" <<'EOF'
XDG_DATA_DIRS="/var/lib/flatpak/exports/share:${HOME}/.local/share/flatpak/exports/share:/usr/local/share:/usr/share"
EOF
    chown -R "$DESKTOP_USER:$DESKTOP_GROUP" "${DESKTOP_HOME}/.config/environment.d"

    run_user xdg-mime default org.kde.discover.desktop application/vnd.flatpak.ref >>"$LOG_FILE" 2>&1 || true
    run_user xdg-mime default org.kde.discover.desktop application/vnd.flatpak.repo >>"$LOG_FILE" 2>&1 || true

    setup_flatpak_desktop_sync_service
    STATUS["Flatpak"]="Integrated with KDE Start, Desktop & Discover Auto-Sync"
    ok "Flatpak & Flathub integrated with KDE Start Menu, Desktop and Discover Auto-Sync"
}

flatpak_install_or_update() {
    local app_id="$1"
    local label="$2"

    ensure_flatpak || return 1

    if flatpak info --system "$app_id" >/dev/null 2>&1; then
        if run_long "Updating $label" flatpak update --system -y "$app_id"; then
            STATUS["$label"]="Updated or latest"
            return 0
        fi
        STATUS["$label"]="Update failed"
        return 1
    fi

    if run_long "Installing $label" flatpak install --system -y flathub "$app_id"; then
        STATUS["$label"]="Installed"
        return 0
    fi

    STATUS["$label"]="Install failed"
    return 1
}

# ==============================================================================
# Audio configuration (Persistent Virtual Sink for Headless / Sunshine)
# ==============================================================================

configure_audio() {
    echo
    echo "========================================="
    echo "Configure Audio (Persistent Virtual Sink)"
    echo "========================================="

    apt_install_or_update pulseaudio-utils pactl "PulseAudio Utilities" || true

    local systemd_user_dir="${DESKTOP_HOME}/.config/systemd/user"
    mkdir -p "$systemd_user_dir"

    cat >"${systemd_user_dir}/virtual-audio-sink.service" <<'EOF'
[Unit]
Description=Virtual Gaming Audio Sink for Sunshine
After=pulseaudio.service pipewire.service sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/pactl load-module module-null-sink sink_name=Virtual_Gaming_Sink sink_properties=device.description=Virtual_Gaming_Sink
ExecStartPost=/usr/bin/pactl set-default-sink Virtual_Gaming_Sink

[Install]
WantedBy=default.target
EOF

    chown -R "$DESKTOP_USER:$DESKTOP_GROUP" "${DESKTOP_HOME}/.config/systemd"
    run_user systemctl --user daemon-reload >>"$LOG_FILE" 2>&1 || true
    run_user systemctl --user enable virtual-audio-sink.service >>"$LOG_FILE" 2>&1 || true

    if run_user pactl info >/dev/null 2>&1; then
        if ! run_user pactl list sinks short 2>/dev/null | grep -q 'Virtual_Gaming_Sink'; then
            run_user pactl load-module module-null-sink sink_name=Virtual_Gaming_Sink sink_properties=device.description=Virtual_Gaming_Sink >>"$LOG_FILE" 2>&1 || true
            run_user pactl set-default-sink Virtual_Gaming_Sink >>"$LOG_FILE" 2>&1 || true
        fi
        STATUS["Audio"]="Virtual Sink Active & Persistent"
        ok "Virtual audio output configured and enabled on boot"
    else
        STATUS["Audio"]="Persistent Service Enabled"
        ok "Virtual audio service enabled (starts on session boot)"
    fi
}

# ==============================================================================
# Selkies/WebRTC removal & NVIDIA driver update
# ==============================================================================

selkies_cleanup_needed() {
    local unit=""
    if pgrep -f 'selkies-gstreamer|selkies-launcher.sh' >/dev/null 2>&1 \
       || [[ -d /opt/selkies-gstreamer ]] \
       || [[ -e /usr/local/bin/selkies-launcher.sh ]]; then
        return 0
    fi

    if [[ -d /etc/supervisor/conf.d ]] \
       && grep -RqiE 'selkies-gstreamer|selkies-launcher' /etc/supervisor/conf.d 2>/dev/null; then
        return 0
    fi

    for unit in selkies.service selkies-gstreamer.service selkies-launcher.service; do
        if systemctl is-active --quiet "$unit" 2>/dev/null \
           || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

remove_selkies_webrtc() {
    echo
    echo "========================================="
    echo "Remove Selkies WebRTC"
    echo "========================================="

    if ! selkies_cleanup_needed; then
        STATUS["Selkies"]="Not active"
        info "Selkies WebRTC is not active; cleanup skipped"
        return 0
    fi

    info "Stopping and removing detected Selkies WebRTC components"
    pkill -KILL -f 'selkies-gstreamer|selkies-launcher.sh' >/dev/null 2>&1 || true

    local unit=""
    for unit in selkies.service selkies-gstreamer.service selkies-launcher.service; do
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
        systemctl --machine="${DESKTOP_USER}@.host" --user stop "$unit" >/dev/null 2>&1 || true
    done

    rm -rf /opt/selkies-gstreamer /usr/local/bin/selkies-launcher.sh /etc/systemd/system/selkies*
    systemctl daemon-reload >/dev/null 2>&1 || true
    STATUS["Selkies"]="Removed"
    ok "Selkies WebRTC removed"
}

nvidia_driver_meta_package() {
    dpkg-query -W -f='${Package}\n' 2>/dev/null \
        | grep -E '^nvidia-driver-[0-9]+(-open)?$' \
        | sort -V \
        | tail -n1
}

nvidia_marker_field() {
    local key="$1"
    [[ -f "$NVIDIA_REBOOT_MARKER" ]] || return 1
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$NVIDIA_REBOOT_MARKER"
}

show_nvidia_reboot_instructions() {
    echo
    echo "========================================================"
    echo "NVIDIA DRIVER UPDATED - REBOOT REQUIRED (NVENC ENABLER)"
    echo "========================================================"
    echo
    echo "NVIDIA packages were updated to enable hardware NVENC streaming."
    echo "Please reboot the VM now to load the updated kernel module:"
    echo "   reboot"
    echo
    echo "After reboot, rerun the script to finish remaining steps:"
    echo "   sudo ./linux-gaming-vm.sh"
    echo "========================================================"
}

update_nvidia_driver_with_reboot() {
    echo
    echo "========================================="
    echo "Update NVIDIA Driver"
    echo "========================================="

    if [[ -f "$NVIDIA_REBOOT_MARKER" ]]; then
        local marker_boot_id=""
        local current_boot_id=""
        local running=""
        local attempt=0

        marker_boot_id="$(nvidia_marker_field boot_id || true)"
        current_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

        if [[ -n "$marker_boot_id" && "$current_boot_id" == "$marker_boot_id" ]]; then
            STATUS["NVIDIA driver update"]="Waiting for reboot"
            warn "NVIDIA driver packages were updated, but VM has not rebooted yet"
            show_nvidia_reboot_instructions
            exit 0
        fi

        while (( attempt < 15 )); do
            running="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
            [[ -n "$running" ]] && break
            sleep 2
            ((attempt+=1))
        done

        if [[ -z "$running" ]]; then
            STATUS["NVIDIA driver update"]="Driver unavailable after reboot"
            error "NVIDIA driver is not responsive after reboot."
            return 1
        fi

        rm -f "$NVIDIA_REBOOT_MARKER"
        STATUS["Driver"]="$running"
        STATUS["NVIDIA driver update"]="Reboot verified (NVENC ready)"
        ok "NVIDIA reboot verified; running driver: $running"
        return 0
    fi

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        STATUS["NVIDIA driver update"]="Skipped"
        warn "NVIDIA driver is not available; driver update skipped"
        return 0
    fi

    refresh_apt_indexes "Refreshing package indexes for NVIDIA" || return 1

    local meta=""
    local installed=""
    local candidate=""
    local running_before=""
    local boot_id_before=""
    local updated=""

    meta="$(nvidia_driver_meta_package || true)"

    if [[ -z "$meta" ]]; then
        STATUS["NVIDIA driver update"]="No metapackage"
        warn "Metapackage not detected; keeping driver as-is"
        return 0
    fi

    installed="$(installed_version "$meta")"
    candidate="$(candidate_version "$meta")"
    running_before="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
    boot_id_before="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

    if [[ -z "$candidate" || "$candidate" == "(none)" ]] || (! dpkg --compare-versions "$candidate" gt "$installed"); then
        STATUS["NVIDIA driver update"]="Already latest"
        ok "NVIDIA driver package is already latest: ${installed:-$running_before}"
        return 0
    fi

    if ! run_long "Updating NVIDIA driver ($meta)" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "$meta"; then
        STATUS["NVIDIA driver update"]="Failed"
        error "NVIDIA driver update failed"
        return 1
    fi

    updated="$(installed_version "$meta")"
    STATUS["NVIDIA driver update"]="Updated to ${updated:-$candidate}"
    ok "NVIDIA driver packages updated to ${updated:-$candidate}"

    {
        printf 'boot_id=%s\n' "$boot_id_before"
        printf 'meta_package=%s\n' "$meta"
        printf 'package_version=%s\n' "${updated:-$candidate}"
        printf 'driver_before=%s\n' "$running_before"
    } >"$NVIDIA_REBOOT_MARKER"
    chmod 600 "$NVIDIA_REBOOT_MARKER"

    show_nvidia_reboot_instructions
    exit 0
}

# ==============================================================================
# System verification
# ==============================================================================

verify_system() {
    echo
    echo "========================================="
    echo "Verify System"
    echo "========================================="

    if curl -fsS --max-time 10 https://tailscale.com >/dev/null 2>&1; then
        STATUS["Internet"]="OK"
        ok "Internet connection available"
    else
        STATUS["Internet"]="Failed"
        error "Internet connection check failed"
    fi

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        STATUS["GPU"]="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
        STATUS["Driver"]="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
        ok "NVIDIA GPU detected: ${STATUS["GPU"]}"
    else
        STATUS["GPU"]="Not detected"
        STATUS["Driver"]="Not detected"
        error "NVIDIA GPU or driver not detected"
    fi

    local free_gb
    free_gb="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"
    STATUS["Free space"]="${free_gb:-Unknown} GB"
    ok "Free disk space: ${free_gb:-Unknown} GB"
}

wait_for_desktop_session() {
    local waited=0
    local timeout=30

    while (( waited < timeout )); do
        if [[ -S "/run/user/${DESKTOP_UID}/bus" ]] \
           && [[ -S /tmp/.X11-unix/X0 || -n "${WAYLAND_DISPLAY:-}" ]]; then
            ok "Desktop session and D-Bus ready"
            return 0
        fi
        sleep 1
        ((waited++))
    done

    write_log INFO "Desktop session waiting timed out; continuing setup"
    return 0
}

# ==============================================================================
# Applications & Gaming Stack
# ==============================================================================

sunshine_asset_url() {
    local release_json="$1"
    local ubuntu_version="${VERSION_ID:-22.04}"

    jq -r --arg version "$ubuntu_version" '
        [
            .assets[]
            | select(.name | test("sunshine-ubuntu-" + ($version | gsub("\\."; "\\\\.")) + "-amd64\\.deb$"; "i"))
        ][0].browser_download_url
        //
        [
            .assets[]
            | select(.name | test("ubuntu.*amd64.*\\.deb$"; "i"))
        ][0].browser_download_url
        //
        empty
    ' <<<"$release_json"
}

install_or_update_sunshine() {
    apt_install_or_update jq jq jq || return 1

    local release_json=""
    local latest_tag=""
    local asset_url=""
    local temp_deb="/tmp/sunshine-latest.deb"
    local installed_package_version=""
    local downloaded_package_version=""

    info "Checking Sunshine version"

    release_json="$(curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest 2>>"$LOG_FILE" || true)"
    if [[ -z "$release_json" ]]; then
        STATUS["Sunshine"]="Version check failed"
        return 1
    fi

    latest_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
    asset_url="$(sunshine_asset_url "$release_json")"

    if [[ -z "$asset_url" ]]; then
        STATUS["Sunshine"]="Compatible package not found"
        return 1
    fi

    if ! run_long "Downloading Sunshine ${latest_tag:-latest}" curl -fL --retry 3 "$asset_url" -o "$temp_deb"; then
        STATUS["Sunshine"]="Download failed"
        return 1
    fi

    downloaded_package_version="$(dpkg-deb -f "$temp_deb" Version 2>/dev/null || true)"
    installed_package_version="$(dpkg-query -W -f='${Version}' sunshine 2>/dev/null || true)"

    if [[ -n "$installed_package_version" && -n "$downloaded_package_version" ]] \
       && ! dpkg --compare-versions "$downloaded_package_version" gt "$installed_package_version"; then
        STATUS["Sunshine"]="Already latest"
        ok "Sunshine is already latest (${latest_tag:-current})"
        rm -f "$temp_deb"
        return 0
    fi

    wait_apt || return 1
    if run_long "Installing Sunshine ${latest_tag:-latest}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$temp_deb"; then
        STATUS["Sunshine"]="Installed/Updated"
        rm -f "$temp_deb"
        return 0
    fi

    STATUS["Sunshine"]="Install or update failed"
    return 1
}

install_and_update_applications() {
    local wine_package="wine"
    local wine_label="Wine"
    local chrome_candidate=""
    local -a apt_packages=()
    local -A versions_before=()

    echo
    echo "========================================="
    echo "Install and Update Gaming Applications"
    echo "========================================="

    # 1. Depozit oficial Kubuntu Backports pentru ultima versiune KDE Plasma
    if ! grep -rq "kubuntu-ppa/backports" /etc/apt/sources.list.d/ 2>/dev/null; then
        info "Adding Kubuntu Backports PPA for latest KDE Plasma"
        env DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:kubuntu-ppa/backports >>"$LOG_FILE" 2>&1 || true
        APT_INDEX_REFRESHED=0
    fi

    # 2. Depozit oficial Google Chrome
    if ! dpkg -s google-chrome-stable >/dev/null 2>&1 && [[ ! -f /etc/apt/sources.list.d/google-chrome.list ]]; then
        info "Configuring Google Chrome repository"
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg >>"$LOG_FILE" 2>&1 || true
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" >/etc/apt/sources.list.d/google-chrome.list
        APT_INDEX_REFRESHED=0
    fi

    # 3. Depozit oficial Tailscale
    if [[ ! -f /etc/apt/sources.list.d/tailscale.list ]]; then
        info "Configuring official Tailscale repository"
        mkdir -p /usr/share/keyrings
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null 2>&1 || true
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null 2>&1 || true
        APT_INDEX_REFRESHED=0
    fi

    refresh_apt_indexes "Updating APT package indexes" || true

    if dpkg -s winehq-staging >/dev/null 2>&1; then
        wine_package="winehq-staging"
        wine_label="Wine Staging"
    elif dpkg -s wine-staging >/dev/null 2>&1; then
        wine_package="wine-staging"
        wine_label="Wine Staging"
    fi

    apt_packages=(
        curl wget ca-certificates gnupg jq ffmpeg libcap2-bin
        gamemode nvtop btop vulkan-tools libvulkan1 mesa-utils
        x11-xserver-utils xinput xcvt pulseaudio-utils inotify-tools
        steam-installer "$wine_package" tailscale
        flatpak plasma-discover plasma-discover-backend-flatpak
        xdg-desktop-portal xdg-desktop-portal-kde xdg-utils
        desktop-file-utils
    )

    chrome_candidate="$(candidate_version google-chrome-stable)"
    if [[ -n "$chrome_candidate" && "$chrome_candidate" != "(none)" ]] || dpkg -s google-chrome-stable >/dev/null 2>&1; then
        apt_packages+=(google-chrome-stable)
    fi

    for package in steam-installer "$wine_package" tailscale; do
        versions_before["$package"]="$(installed_version "$package")"
    done
    [[ -n "$chrome_candidate" ]] && versions_before["google-chrome-stable"]="$(installed_version google-chrome-stable)"

    wait_apt || return 1
    run_long "Installing/updating Gaming packages" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${apt_packages[@]}" || true

    set_batch_package_status Steam steam-installer steam "${versions_before[steam-installer]}" || true
    set_batch_package_status "$wine_label" "$wine_package" wine "${versions_before[$wine_package]}" || true
    set_batch_package_status Tailscale tailscale tailscale "${versions_before[tailscale]}" || true
    
    if [[ -n "$chrome_candidate" ]]; then
        set_batch_package_status "Google Chrome" google-chrome-stable google-chrome "${versions_before[google-chrome-stable]}" || true
    fi

    ensure_flatpak || true
    flatpak_install_or_update net.davidotek.pupgui2 ProtonUp-Qt || true

    install_or_update_sunshine || true
}

# ==============================================================================
# Tailscale & Sunshine (cu Robust Auto-Resolution Switcher)
# ==============================================================================

configure_tailscale() {
    echo
    echo "========================================="
    echo "Configure Tailscale"
    echo "========================================="

    systemctl enable --now tailscaled >>"$LOG_FILE" 2>&1 || true

    if ! tailscale status >/dev/null 2>&1; then
        if [[ -t 0 ]]; then
            echo
            tailscale up 2>&1 | tee -a "$LOG_FILE" || true
        else
            warn "Tailscale requires interactive login"
        fi
    fi

    if tailscale status >/dev/null 2>&1; then
        TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
        SUNSHINE_URL="https://${TAILSCALE_IP}:47990"
        STATUS["Tailscale"]="Connected (IP: $TAILSCALE_IP)"
        ok "Tailscale connected (IP: $TAILSCALE_IP)"
    else
        STATUS["Tailscale"]="Not connected"
        warn "Tailscale not connected"
    fi
}

find_sunshine_service() {
    local service
    for service in app-dev.lizardbyte.app.Sunshine.service sunshine.service; do
        if [[ -f "/usr/lib/systemd/user/${service}" \
           || -f "/usr/share/systemd/user/${service}" \
           || -f "${DESKTOP_HOME}/.config/systemd/user/${service}" ]]; then
            echo "$service"
            return 0
        fi
    done
    return 1
}

set_sunshine_option() {
    local config_file="$1"
    local key="$2"
    local value="$3"

    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$config_file"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$config_file"
    else
        printf '%s = %s\n' "$key" "$value" >>"$config_file"
    fi
}

configure_sunshine_privileges() {
    local sunshine_bin
    sunshine_bin="$(readlink -f "$(command -v sunshine 2>/dev/null)" 2>/dev/null || true)"

    if [[ -z "$sunshine_bin" || ! -f "$sunshine_bin" ]]; then
        STATUS["Sunshine privileges"]="Missing binary"
        return 1
    fi

    setcap cap_sys_admin,cap_sys_nice+p "$sunshine_bin" >>"$LOG_FILE" 2>&1 || true
    STATUS["Sunshine privileges"]="CAP_SYS_NICE enabled"
}

setup_sunshine_resolution_tool() {
    cat >/usr/local/bin/sunshine-resolution.sh <<'EOF_RES_TOOL'
#!/usr/bin/env bash
export DISPLAY="${DISPLAY:-:0}"

if [[ -z "${XAUTHORITY:-}" ]]; then
    export XAUTHORITY="$(find /home /run/user /tmp -maxdepth 3 -name ".Xauthority" -o -name "*auth*" 2>/dev/null | head -n1)"
fi

WIDTH="${SUNSHINE_CLIENT_WIDTH:-${1:-1920}}"
HEIGHT="${SUNSHINE_CLIENT_HEIGHT:-${2:-1080}}"
FPS="${SUNSHINE_CLIENT_FPS:-${3:-60}}"

OUTPUT="$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1; exit}')"
[[ -z "$OUTPUT" ]] && OUTPUT="$(xrandr --query 2>/dev/null | awk 'NR==2 {print $1}')"
[[ -z "$OUTPUT" ]] && OUTPUT="default"

RAW_MODELINE="$(cvt -r "$WIDTH" "$HEIGHT" "$FPS" 2>/dev/null | grep Modeline)"
if [[ -z "$RAW_MODELINE" ]]; then
    RAW_MODELINE="$(cvt "$WIDTH" "$HEIGHT" "$FPS" 2>/dev/null | grep Modeline)"
fi

if [[ -n "$RAW_MODELINE" ]]; then
    MODE_NAME="$(echo "$RAW_MODELINE" | awk '{print $2}' | tr -d '"')"
    MODELINE_ARGS="$(echo "$RAW_MODELINE" | sed -E 's/^[[:space:]]*Modeline[[:space:]]+"[^"]+"[[:space:]]+//')"

    if ! xrandr --query 2>/dev/null | grep -qF "$MODE_NAME"; then
        # shellcheck disable=SC2086
        xrandr --newmode "$MODE_NAME" $MODELINE_ARGS 2>/dev/null || true
    fi

    xrandr --addmode "$OUTPUT" "$MODE_NAME" 2>/dev/null || true
    xrandr --output "$OUTPUT" --mode "$MODE_NAME" 2>/dev/null || true

    if command -v kscreen-doctor >/dev/null 2>&1; then
        kscreen-doctor "output.${OUTPUT}.mode.${MODE_NAME}" 2>/dev/null || true
    fi
fi
EOF_RES_TOOL
    chmod 755 /usr/local/bin/sunshine-resolution.sh

    local config_dir="${DESKTOP_HOME}/.config/sunshine"
    mkdir -p "$config_dir"
    cat >"${config_dir}/apps.json" <<'EOF_APPS'
{
  "env": {
    "PATH": "$(PATH):/usr/local/bin"
  },
  "apps": [
    {
      "name": "Desktop",
      "image-path": "desktop.png",
      "prep-cmd": [
        {
          "do": "/usr/local/bin/sunshine-resolution.sh",
          "undo": "/usr/local/bin/sunshine-resolution.sh 1920 1080 60"
        }
      ]
    }
  ]
}
EOF_APPS
    chown -R "$DESKTOP_USER:$DESKTOP_GROUP" "$config_dir"
}

configure_sunshine() {
    echo
    echo "========================================="
    echo "Configure Sunshine"
    echo "========================================="

    if ! command -v sunshine >/dev/null 2>&1; then
        STATUS["Sunshine"]="Missing"
        return 1
    fi

    local config_dir="${DESKTOP_HOME}/.config/sunshine"
    local config_file="${config_dir}/sunshine.conf"
    local service

    install -d -m 700 -o "$DESKTOP_USER" -g "$DESKTOP_GROUP" "$config_dir"
    touch "$config_file"
    chown "$DESKTOP_USER:$DESKTOP_GROUP" "$config_file"
    chmod 600 "$config_file" || true

    sed -i -E '/^[[:space:]]*capture[[:space:]]*=/d' "$config_file"
    set_sunshine_option "$config_file" encoder nvenc
    set_sunshine_option "$config_file" upnp disabled
    set_sunshine_option "$config_file" origin_web_ui_allowed wan

    if [[ "$TAILSCALE_IP" != "Not connected" ]]; then
        set_sunshine_option "$config_file" csrf_allowed_origins "https://${TAILSCALE_IP}:47990"
    fi

    setup_sunshine_resolution_tool

    mkdir -p "${DESKTOP_HOME}/.config/autostart"
    cat >"${DESKTOP_HOME}/.config/autostart/sunshine.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Exec=sunshine
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Sunshine
EOF
    chown -R "$DESKTOP_USER:$DESKTOP_GROUP" "${DESKTOP_HOME}/.config/autostart"

    service="$(find_sunshine_service || true)"

    if [[ -z "$service" ]]; then
        STATUS["Sunshine"]="Service not found"
        return 1
    fi

    run_user systemctl --user stop "$service" >>"$LOG_FILE" 2>&1 || true
    pkill -TERM -x sunshine >>"$LOG_FILE" 2>&1 || true
    sleep 1
    pkill -KILL -x sunshine >>"$LOG_FILE" 2>&1 || true

    configure_sunshine_privileges || true

    run_user systemctl --user daemon-reload >>"$LOG_FILE" 2>&1 || true
    run_user systemctl --user enable --now "$service" >>"$LOG_FILE" 2>&1 || true

    STATUS["Sunshine"]="Running (Autostart on boot)"
    ok "Sunshine configured with Moonlight auto-resolution switcher"
}

# ==============================================================================
# Host Gaming Optimizations (Sysctl, Proton & CPU Governor)
# ==============================================================================

configure_host_optimizations() {
    echo
    echo "========================================="
    echo "Host Gaming & Kernel Optimizations"
    echo "========================================="

    cat >/etc/sysctl.d/99-gaming.conf <<'EOF'
vm.max_map_count = 2147483642
fs.file-max = 2097152
EOF
    sysctl --system >>"$LOG_FILE" 2>&1 || true
    ok "Kernel sysctl applied (vm.max_map_count=2147483642 for Proton/UE5)"

    cat >/etc/security/limits.d/99-gaming.conf <<EOF
$DESKTOP_USER soft nofile 524288
$DESKTOP_USER hard nofile 524288
EOF
    ok "ESync/FSync file descriptor limits configured"

    local governor_file
    for governor_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -e "$governor_file" ]] || continue
        printf '%s' performance >"$governor_file" 2>>"$LOG_FILE" || true
    done
    ok "CPU Governor optimization checked"

    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -pm 1 >>"$LOG_FILE" 2>&1 || true
        ok "NVIDIA Persistence mode enabled"
    fi
}

# ==============================================================================
# Mouse Acceleration Fix (Flat Profile for Headless)
# ==============================================================================

configure_mouse_acceleration() {
    echo
    echo "========================================="
    echo "Mouse Acceleration"
    echo "========================================="
    echo
    echo "[1] Disable (Flat Profile - 1:1 Raw Input)"
    echo "[2] Keep Current Setting"
    echo
    echo "Choice:"

    if [[ ! -t 0 ]]; then
        return 0
    fi

    local choice
    while read -r choice; do
        case "$choice" in
            1)
                mkdir -p "${DESKTOP_HOME}/.config"
                if command -v kwriteconfig6 >/dev/null 2>&1; then
                    run_user kwriteconfig6 --file kcminputrc --group Mouse --key XLbInptAccelProfileFlat true
                    run_user kwriteconfig6 --file kcminputrc --group Mouse --key PointerAcceleration 0
                elif command -v kwriteconfig5 >/dev/null 2>&1; then
                    run_user kwriteconfig5 --file kcminputrc --group Mouse --key XLbInptAccelProfileFlat true
                    run_user kwriteconfig5 --file kcminputrc --group Mouse --key PointerAcceleration 0
                fi

                if command -v xinput >/dev/null 2>&1; then
                    local device_id
                    while read -r device_id; do
                        [[ -n "$device_id" ]] || continue
                        if run_user xinput list-props "$device_id" 2>/dev/null | grep -q "libinput Accel Profile Enabled"; then
                            run_user xinput set-prop "$device_id" "libinput Accel Profile Enabled" 0 1 >>"$LOG_FILE" 2>&1 \
                               || run_user xinput set-prop "$device_id" "libinput Accel Profile Enabled" 0 1 0 >>"$LOG_FILE" 2>&1 || true
                            run_user xinput set-prop "$device_id" "libinput Accel Speed" 0 >>"$LOG_FILE" 2>&1 || true
                        fi
                    done < <(run_user xinput list --id-only 2>/dev/null || true)
                fi

                STATUS["Mouse acceleration"]="Disabled (Flat 1:1)"
                ok "Mouse acceleration disabled (Flat profile 0 1 applied)"
                break
                ;;
            2)
                ok "Mouse acceleration kept"
                break
                ;;
            *)
                echo "Enter 1 or 2:"
                ;;
        esac
    done
}

# ==============================================================================
# Display & High Refresh Rates (Headless Robust Mode)
# ==============================================================================

primary_output() {
    run_user xrandr --query 2>/dev/null \
        | awk '
            / connected primary / {print $1; exit}
            / connected / && !fallback {fallback=$1}
            END {if (fallback) print fallback; else print "default"}
        ' \
        | head -n1
}

current_resolution() {
    run_user xrandr --current 2>/dev/null \
        | awk '/ connected / {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) {split($i, a, "+"); print a[1]; exit}}'
}

current_refresh() {
    run_user xrandr --current 2>/dev/null \
        | awk '/\*/ {value=$2; gsub(/[^0-9.]/, "", value); print value; exit}'
}

choose_resolution() {
    cat <<'EOF'

=========================================
Choose Display Resolution
=========================================
[1] 1024x768
[2] 1280x720
[3] 1920x1080
[4] 2560x1440
[5] 3840x2160
[6] 2560x1080 (Ultrawide)
[7] 3440x1440 (Ultrawide)
[8] Keep Current Resolution

Choice:
EOF

    if [[ ! -t 0 ]]; then
        RESOLUTION="$(current_resolution || echo "Keep current")"
        return
    fi

    local choice
    while read -r choice; do
        case "$choice" in
            1) RESOLUTION="1024x768" ;;
            2) RESOLUTION="1280x720" ;;
            3) RESOLUTION="1920x1080" ;;
            4) RESOLUTION="2560x1440" ;;
            5) RESOLUTION="3840x2160" ;;
            6) RESOLUTION="2560x1080" ;;
            7) RESOLUTION="3440x1440" ;;
            8) RESOLUTION="$(current_resolution || echo "Keep current")" ;;
            *) echo "Enter a valid number:" ; continue ;;
        esac
        break
    done
}

choose_refresh() {
    cat <<'EOF'

=========================================
Choose Refresh Rate
=========================================
[1] 60 Hz
[2] 90 Hz
[3] 120 Hz
[4] 144 Hz
[5] 165 Hz
[6] 240 Hz
[7] Keep Current Refresh Rate

Choice:
EOF

    if [[ ! -t 0 ]]; then
        REFRESH_RATE="$(current_refresh || echo "Keep current")"
        return
    fi

    local choice
    while read -r choice; do
        case "$choice" in
            1) REFRESH_RATE="60" ;;
            2) REFRESH_RATE="90" ;;
            3) REFRESH_RATE="120" ;;
            4) REFRESH_RATE="144" ;;
            5) REFRESH_RATE="165" ;;
            6) REFRESH_RATE="240" ;;
            7) REFRESH_RATE="$(current_refresh || echo "Keep current")" ;;
            *) echo "Enter a valid number:" ; continue ;;
        esac
        break
    done
}

apply_display() {
    local output
    local width
    local height
    local raw_modeline
    local mode_name
    local modeline_args

    output="$(primary_output)"
    [[ -z "$output" ]] && output="default"

    width="${RESOLUTION%x*}"
    height="${RESOLUTION#*x}"

    raw_modeline="$(cvt -r "$width" "$height" "$REFRESH_RATE" 2>/dev/null | grep Modeline)"
    if [[ -z "$raw_modeline" ]]; then
        raw_modeline="$(cvt "$width" "$height" "$REFRESH_RATE" 2>/dev/null | grep Modeline)"
    fi

    if [[ -n "$raw_modeline" ]]; then
        mode_name="$(echo "$raw_modeline" | awk '{print $2}' | tr -d '"')"
        modeline_args="$(echo "$raw_modeline" | sed -E 's/^[[:space:]]*Modeline[[:space:]]+"[^"]+"[[:space:]]+//')"

        if ! run_user xrandr --query 2>/dev/null | grep -qF "$mode_name"; then
            # shellcheck disable=SC2086
            run_user xrandr --newmode "$mode_name" $modeline_args >>"$LOG_FILE" 2>&1 || true
        fi

        run_user xrandr --addmode "$output" "$mode_name" >>"$LOG_FILE" 2>&1 || true

        if run_user xrandr --output "$output" --mode "$mode_name" >>"$LOG_FILE" 2>&1; then
            ok "Display configured: $RESOLUTION @ $REFRESH_RATE Hz"
            run_user kscreen-doctor "output.${output}.mode.${mode_name}" >>"$LOG_FILE" 2>&1 || true
            return 0
        fi
    fi

    if run_user xrandr -s "${width}x${height}" >>"$LOG_FILE" 2>&1; then
        ok "Display set via size fallback: $RESOLUTION"
        return 0
    fi

    warn "Display resolution configured for Moonlight dynamic streaming"
    return 0
}

configure_display() {
    echo
    echo "========================================="
    echo "Configure Display"
    echo "========================================="

    choose_resolution
    choose_refresh

    if [[ "$RESOLUTION" == "Keep current" ]]; then
        RESOLUTION="$(current_resolution || echo "Keep current")"
    fi
    if [[ "$REFRESH_RATE" == "Keep current" ]]; then
        REFRESH_RATE="$(current_refresh || echo "Keep current")"
    fi

    if [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ && "$REFRESH_RATE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        apply_display || true
    fi

    STATUS["Resolution"]="$RESOLUTION"
    STATUS["Refresh rate"]="${REFRESH_RATE} Hz"
}

# ==============================================================================
# Transparent Dark Theme & Desktop Shortcuts
# ==============================================================================

apply_kde_dark_theme() {
    local config_tool=""

    if command -v kwriteconfig6 >/dev/null 2>&1; then
        config_tool="kwriteconfig6"
    elif command -v kwriteconfig5 >/dev/null 2>&1; then
        config_tool="kwriteconfig5"
    else
        return 1
    fi

    # 1. KDE Plasma Configs
    run_user "$config_tool" --file kdeglobals --group General --key ColorScheme BreezeDark >>"$LOG_FILE" 2>&1 || true
    run_user "$config_tool" --file kdeglobals --group KDE --key LookAndFeelPackage org.kde.breezedark.desktop >>"$LOG_FILE" 2>&1 || true
    run_user "$config_tool" --file plasmarc --group Theme --key name breeze-dark >>"$LOG_FILE" 2>&1 || true

    # 2. Activare Transparență & Blur în KWin
    run_user "$config_tool" --file kwinrc --group Plugins --key blurEnabled true >>"$LOG_FILE" 2>&1 || true
    run_user "$config_tool" --file kwinrc --group Plugins --key contrastEnabled true >>"$LOG_FILE" 2>&1 || true
    run_user "$config_tool" --file kwinrc --group Plugins --key translucencyEnabled true >>"$LOG_FILE" 2>&1 || true
    run_user "$config_tool" --file kwinrc --group Effect-blur --key BlurStrength 12 >>"$LOG_FILE" 2>&1 || true

    # 3. Integrare completă Dark Theme pentru aplicații GTK 3 & GTK 4 (Chrome, etc.)
    mkdir -p "${DESKTOP_HOME}/.config/gtk-3.0" "${DESKTOP_HOME}/.config/gtk-4.0"
    cat >"${DESKTOP_HOME}/.config/gtk-3.0/settings.ini" <<'EOF_GTK'
[Settings]
gtk-theme-name=Breeze-Dark
gtk-application-prefer-dark-theme=1
EOF_GTK
    cp "${DESKTOP_HOME}/.config/gtk-3.0/settings.ini" "${DESKTOP_HOME}/.config/gtk-4.0/settings.ini"
    chown -R "$DESKTOP_USER:$DESKTOP_GROUP" "${DESKTOP_HOME}/.config/gtk-3.0" "${DESKTOP_HOME}/.config/gtk-4.0"

    # 4. Semnale live către D-Bus
    if command -v plasma-apply-colorscheme >/dev/null 2>&1; then
        run_user plasma-apply-colorscheme BreezeDark >>"$LOG_FILE" 2>&1 || true
    fi
    if command -v lookandfeeltool >/dev/null 2>&1; then
        run_user lookandfeeltool -a org.kde.breezedark.desktop >>"$LOG_FILE" 2>&1 || true
    fi
    if command -v plasma-apply-lookandfeel >/dev/null 2>&1; then
        run_user plasma-apply-lookandfeel -a org.kde.breezedark.desktop >>"$LOG_FILE" 2>&1 || true
    fi

    run_user qdbus org.kde.KWin /KWin reconfigure >>"$LOG_FILE" 2>&1 || true
}

apply_wallpaper() {
    local wallpaper_url="https://images.hdqwalls.com/wallpapers/penguin-linux-4k-83.jpg"
    local wallpaper_dir="/usr/share/wallpapers/Linux-Gaming-VM"
    local wallpaper_file="${wallpaper_dir}/wallpaper.jpg"
    local qdbus_command=""

    mkdir -p "$wallpaper_dir" >>"$LOG_FILE" 2>&1 || return 0

    info "Downloading desktop wallpaper"

    if ! curl -fsSL -A "Mozilla/5.0 (X11; Linux x86_64)" "$wallpaper_url" -o "$wallpaper_file" >>"$LOG_FILE" 2>&1; then
        write_log WARN "Wallpaper could not be downloaded from $wallpaper_url"
        return 0
    fi

    chmod 644 "$wallpaper_file" >>"$LOG_FILE" 2>&1 || true

    if command -v qdbus6 >/dev/null 2>&1; then
        qdbus_command="qdbus6"
    elif command -v qdbus >/dev/null 2>&1; then
        qdbus_command="qdbus"
    elif command -v qdbus-qt5 >/dev/null 2>&1; then
        qdbus_command="qdbus-qt5"
    else
        write_log INFO "Wallpaper downloaded, but qdbus is unavailable"
        return 0
    fi

    local plasma_script
    plasma_script="var ds = desktops(); for (var i = 0; i < ds.length; i++) { ds[i].wallpaperPlugin = 'org.kde.image'; ds[i].currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General']; ds[i].writeConfig('Image', 'file://$wallpaper_file'); }"

    if run_user "$qdbus_command" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript "$plasma_script" \
        >>"$LOG_FILE" 2>&1; then
        write_log OK "Wallpaper applied successfully"
        ok "KDE Wallpaper applied"
    else
        write_log WARN "Wallpaper could not be applied automatically via D-Bus"
    fi
}

configure_desktop() {
    echo
    echo "========================================="
    echo "Configure Desktop & Shortcuts"
    echo "========================================="

    install -d -m 755 -o "$DESKTOP_USER" -g "$DESKTOP_GROUP" "${DESKTOP_HOME}/Desktop"

    create_shortcut Steam steam.desktop steam-installer.desktop '*steam*.desktop' || true
    create_shortcut "Google Chrome" google-chrome.desktop 'google-chrome*.desktop' || true

    local sunshine_shortcut="${DESKTOP_HOME}/Desktop/Sunshine Web UI.desktop"
    local trash_shortcut="${DESKTOP_HOME}/Desktop/Trash.desktop"
    local shortcut_url="$SUNSHINE_URL"

    if [[ "$shortcut_url" == "Unavailable" ]]; then
        shortcut_url="https://localhost:47990"
    fi

    cat >"$sunshine_shortcut" <<EOF
[Desktop Entry]
Type=Application
Name=Sunshine Web UI
Comment=Open Sunshine Web Interface
Exec=xdg-open ${shortcut_url}
Icon=applications-internet
Terminal=false
Categories=Network;
EOF

    cat >"$trash_shortcut" <<'EOF'
[Desktop Entry]
Type=Link
Name=Trash
Icon=user-trash
URL=trash:/
EOF

    chown "$DESKTOP_USER:$DESKTOP_GROUP" "$sunshine_shortcut" "$trash_shortcut" || true
    chmod +x "$sunshine_shortcut" "$trash_shortcut" || true
    run_user gio set "$sunshine_shortcut" metadata::trusted true 2>/dev/null || true
    run_user gio set "$trash_shortcut" metadata::trusted true 2>/dev/null || true

    if apply_kde_dark_theme; then
        STATUS["Theme"]="Dark Translucent (Blur enabled)"
    fi

    apply_wallpaper

    ok "Desktop shortcuts, KDE transparent dark theme, and wallpaper configured"
}

# ==============================================================================
# Summary & Reboot Recommendation
# ==============================================================================

value() {
    local key="$1"
    printf '%s' "${STATUS[$key]:-Not detected}"
}

summary() {
    echo
    echo "========================================="
    echo "Linux-Gaming-VM Setup Completed"
    echo "========================================="
    echo
    printf '%-20s %s\n' "GPU.............." "$(value GPU)"
    printf '%-20s %s\n' "Driver..........." "$(value Driver)"
    printf '%-20s %s\n' "Audio Output....." "$(value Audio)"
    printf '%-20s %s\n' "Flatpak & KDE...." "$(value Flatpak)"
    printf '%-20s %s\n' "Tailscale........" "$(value Tailscale)"
    printf '%-20s %s\n' "Sunshine........." "$(value Sunshine)"
    printf '%-20s %s\n' "Resolution......." "$(value Resolution) @ $(value "Refresh rate")"
    echo
    printf '%-20s %s\n' "Tailscale IP....." "$TAILSCALE_IP"
    printf '%-20s %s\n' "Sunshine UI......" "$SUNSHINE_URL"
    echo "========================================="
    echo
    printf '%s[RECOMMANDATION]%s Please REBOOT the virtual machine now!\n' "$YELLOW" "$RESET"
    printf '                 A reboot ensures that the Dark Translucent theme,\n'
    printf '                 all audio sinks, and display settings take effect\n'
    printf '                 globally across all GTK, Qt, and Flatpak apps.\n'
    echo
    printf 'Run: %ssudo reboot%s\n' "$GREEN" "$RESET"
    echo "========================================="
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    require_root

    if ! self_check_script >/dev/null; then
        self_check_script || true
        exit 1
    fi

    init_log
    banner
    detect_environment
    disable_automatic_updates || exit 1

    remove_selkies_webrtc
    update_nvidia_driver_with_reboot

    verify_system
    wait_for_desktop_session
    install_and_update_applications

    configure_audio
    configure_tailscale
    configure_sunshine
    configure_host_optimizations
    configure_desktop
    configure_mouse_acceleration
    configure_display

    summary
}

if [[ "${1:-}" == "--self-check" ]]; then
    self_check_script
    exit $?
fi

main "$@"