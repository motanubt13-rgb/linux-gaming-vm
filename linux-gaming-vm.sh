#!/usr/bin/env bash
# ==============================================================================
# Linux-Gaming-VM
# Version 1.4 Test 2 (manual reboot marker)
#
# Designed for Vast.ai KVM virtual machines running Ubuntu with KDE Plasma.
# ==============================================================================

set -u
set -o pipefail

SCRIPT_NAME="Linux-Gaming-VM"
SCRIPT_VERSION="1.4-test2"
SCRIPT_BUILD="2026-08-08-r2"

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

# Runs a command in the background.
# If its output contains a real NN% value, that value is displayed.
# Otherwise, an animated spinner is shown.
run_long() {
    local description="$1"
    shift

    local temp_file
    local pid rc
    local spinner='|/-\'
    local spin_index=0
    local percent=""
    local last_percent=""

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
            last_percent="$percent"
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
Version 1.4 Test 2
Build 2026-08-08-r2
=========================================

This script is designed for Vast.ai KVM virtual machines.

Missing components will be installed.
Outdated components will be updated.
Components that are already up to date will be left unchanged.

Please note:
Although this script has been tested, unexpected errors may still occur depending on your system configuration.

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

    # Guard against the exact set -u bug that previously stopped Sunshine:
    # a variable must not be referenced by another assignment in the same
    # local declaration before Bash has made it available.
    if awk '
        /^[[:space:]]*local[[:space:]]+dir=.*file=.*[$]dir/ { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$script_path"; then
        echo "[SELF-CHECK ERROR] Unsafe Sunshine local-variable declaration detected."
        ((failures++)) || true
    fi

    # Duplicate function definitions are usually an accidental merge/edit.
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

    # These functions are critical to the two-stage NVIDIA/Sunshine workflow.
    for required_function in \
        detect_environment \
        remove_selkies_webrtc \
        update_nvidia_driver_with_reboot \
        install_and_update_applications \
        configure_tailscale \
        configure_sunshine \
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
            DESKTOP_USER="$(getent passwd 1000 | cut -d: -f1)"
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

    if [[ -f "/run/user/${DESKTOP_UID}/gdm/Xauthority" ]]; then
        XAUTHORITY_VALUE="/run/user/${DESKTOP_UID}/gdm/Xauthority"
    fi

    SUPPORT_LOG="${DESKTOP_HOME}/.local/share/.linux-gaming-vm/linux-gaming-vm.log"

    STATUS["Desktop user"]="$DESKTOP_USER"
    STATUS["Desktop group"]="$DESKTOP_GROUP"

    ok "Desktop user detected: $DESKTOP_USER"
    write_log INFO "Desktop group detected: $DESKTOP_GROUP"
    write_log INFO "DISPLAY=$DISPLAY_VALUE"
    write_log INFO "XAUTHORITY=$XAUTHORITY_VALUE"
}

disable_automatic_updates() {
    echo
    echo "========================================="
    echo "Prepare Package Manager"
    echo "========================================="

    info "Disabling Ubuntu automatic updates permanently"

    # Prevent the timers from starting new automatic APT jobs.
    systemctl stop apt-daily.timer apt-daily-upgrade.timer \
        >>"$LOG_FILE" 2>&1 || true

    systemctl disable apt-daily.timer apt-daily-upgrade.timer \
        >>"$LOG_FILE" 2>&1 || true

    systemctl mask apt-daily.timer apt-daily-upgrade.timer \
        >>"$LOG_FILE" 2>&1 || true

    # Stop currently running automatic update services gracefully.
    systemctl stop apt-daily.service apt-daily-upgrade.service \
        unattended-upgrades.service >>"$LOG_FILE" 2>&1 || true

    systemctl disable unattended-upgrades.service \
        >>"$LOG_FILE" 2>&1 || true

    systemctl mask apt-daily.service apt-daily-upgrade.service \
        unattended-upgrades.service >>"$LOG_FILE" 2>&1 || true

    # Disable periodic APT activity at the configuration level as well.
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

    # Ask any remaining unattended-upgrade process to exit cleanly.
    pkill -TERM -f '/usr/bin/unattended-upgrade' \
        >>"$LOG_FILE" 2>&1 || true
    pkill -TERM -f '/usr/lib/apt/apt.systemd.daily' \
        >>"$LOG_FILE" 2>&1 || true

    local waited=0

    while pgrep -f '/usr/bin/unattended-upgrade|/usr/lib/apt/apt.systemd.daily' \
        >/dev/null 2>&1; do

        if (( waited >= 30 )); then
            write_log WARN \
                "Automatic update processes did not stop within 30 seconds; forcing termination"

            pkill -KILL -f '/usr/bin/unattended-upgrade' \
                >>"$LOG_FILE" 2>&1 || true
            pkill -KILL -f '/usr/lib/apt/apt.systemd.daily' \
                >>"$LOG_FILE" 2>&1 || true
            break
        fi

        sleep 1
        ((waited++)) || true
    done

    # Wait until APT/DPKG locks are released.
    waited=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do

        if (( waited >= 60 )); then
            error "Package manager locks were not released after stopping automatic updates"
            return 1
        fi

        sleep 1
        ((waited++)) || true
    done

    # Repair any package configuration interrupted by stopping the updater.
    if ! env DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
        >>"$LOG_FILE" 2>&1; then
        error "Pending package configuration could not be completed"
        return 1
    fi

    STATUS["Automatic updates"]="Disabled"
    ok "Ubuntu automatic updates disabled"
}

wait_apt() {
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do

        if (( waited == 0 )); then
            warn "APT is busy. Waiting for the package manager..."
        fi

        if (( waited >= 900 )); then
            error "APT remained locked for more than 15 minutes."
            return 1
        fi

        sleep 5
        ((waited+=5))
    done
}

# ==============================================================================
# Version and package helpers
# ==============================================================================

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

        if run_long "Installing $label" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
            STATUS["$label"]="Installed"
            return 0
        fi

        STATUS["$label"]="Install failed"
        return 1
    fi

    if version_is_newer "$candidate" "$installed"; then
        wait_apt || return 1

        if run_long "Updating $label" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "$package"; then
            STATUS["$label"]="Updated"
            return 0
        fi

        STATUS["$label"]="Update failed"
        return 1
    fi

    if command -v "$command_name" >/dev/null 2>&1 || dpkg -s "$package" >/dev/null 2>&1; then
        STATUS["$label"]="Already latest"
        ok "$label is already latest"
        return 0
    fi

    STATUS["$label"]="Installed"
    ok "$label is installed"
}

ensure_flatpak() {
    apt_install_or_update flatpak flatpak Flatpak || return 1

    if ! flatpak remotes --system --columns=name 2>/dev/null | grep -qx flathub; then
        if run_long "Configuring Flathub" \
            flatpak remote-add --system --if-not-exists \
            flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
            ok "Flathub configured"
        else
            return 1
        fi
    fi
}

flatpak_install_or_update() {
    local app_id="$1"
    local label="$2"

    ensure_flatpak || return 1

    if flatpak info --system "$app_id" >/dev/null 2>&1; then
        if run_long "Updating $label" \
            flatpak update --system -y "$app_id"; then
            STATUS["$label"]="Updated or already latest"
            return 0
        fi

        STATUS["$label"]="Update failed"
        return 1
    fi

    if run_long "Installing $label" \
        flatpak install --system -y flathub "$app_id"; then
        STATUS["$label"]="Installed"
        return 0
    fi

    STATUS["$label"]="Install failed"
    return 1
}

# ==============================================================================
# Selkies/WebRTC removal and NVIDIA driver update with manual reboot marker
# ==============================================================================

remove_selkies_webrtc() {
    echo
    echo "========================================="
    echo "Remove Selkies WebRTC"
    echo "========================================="

    info "Stopping and removing Selkies WebRTC components"

    # Stop restart loops before removing files.
    pkill -TERM -f '/opt/selkies-gstreamer|selkies-gstreamer|selkies-launcher.sh' \
        >>"$LOG_FILE" 2>&1 || true
    sleep 1
    pkill -KILL -f '/opt/selkies-gstreamer|selkies-gstreamer|selkies-launcher.sh' \
        >>"$LOG_FILE" 2>&1 || true

    # Remove Supervisor entries that explicitly launch Selkies.
    local supervisor_file
    if [[ -d /etc/supervisor/conf.d ]]; then
        while IFS= read -r supervisor_file; do
            [[ -n "$supervisor_file" ]] || continue
            if grep -qiE 'selkies-gstreamer|selkies-launcher' "$supervisor_file" 2>/dev/null; then
                write_log INFO "Removing Selkies Supervisor config: $supervisor_file"
                rm -f "$supervisor_file"
            fi
        done < <(find /etc/supervisor/conf.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null)

        if command -v supervisorctl >/dev/null 2>&1; then
            supervisorctl reread >>"$LOG_FILE" 2>&1 || true
            supervisorctl update >>"$LOG_FILE" 2>&1 || true
        fi
    fi

    # Disable known system and user services if they exist.
    local unit
    for unit in selkies.service selkies-gstreamer.service selkies-launcher.service; do
        systemctl disable --now "$unit" >>"$LOG_FILE" 2>&1 || true
        systemctl --machine="${DESKTOP_USER}@.host" --user \
            disable --now "$unit" >>"$LOG_FILE" 2>&1 || true
    done

    rm -f \
        /usr/local/bin/selkies-launcher.sh \
        /etc/systemd/system/selkies.service \
        /etc/systemd/system/selkies-gstreamer.service \
        /etc/systemd/system/selkies-launcher.service

    rm -rf /opt/selkies-gstreamer

    if [[ -d "${DESKTOP_HOME}/.config/autostart" ]]; then
        find "${DESKTOP_HOME}/.config/autostart" -maxdepth 1 -type f \
            -iname '*selkies*' -delete 2>/dev/null || true
    fi

    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true

    if pgrep -f 'selkies-gstreamer|selkies-launcher.sh' >/dev/null 2>&1; then
        STATUS["Selkies"]="Still running"
        warn "A Selkies process is still running"
    else
        STATUS["Selkies"]="Removed"
        ok "Selkies WebRTC removed"
    fi
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
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' \
        "$NVIDIA_REBOOT_MARKER"
}

show_nvidia_reboot_instructions() {
    echo
    echo "========================================="
    echo "NVIDIA DRIVER UPDATED - REBOOT REQUIRED"
    echo "========================================="
    echo
    echo "The NVIDIA packages were updated successfully."
    echo "The currently loaded kernel driver cannot be replaced safely without a reboot."
    echo
    echo "1. Reboot the VM:"
    echo "   reboot"
    echo
    echo "2. After the VM starts, open the terminal again."
    echo
    echo "3. Run this same script again:"
    echo "   sudo ./linux-gaming-vm.sh"
    echo
    echo "The reboot marker will be detected automatically and setup will continue."
    echo "========================================="
}

update_nvidia_driver_with_reboot() {
    echo
    echo "========================================="
    echo "Update NVIDIA Driver"
    echo "========================================="

    # If a marker exists, a driver package update already completed on a prior
    # run. We verify that the machine actually rebooted by comparing Linux boot
    # IDs. This is more reliable than comparing Debian package revisions with
    # nvidia-smi's driver version string.
    if [[ -f "$NVIDIA_REBOOT_MARKER" ]]; then
        local marker_boot_id=""
        local current_boot_id=""
        local expected_meta=""
        local expected_package=""
        local running=""
        local attempt=0

        marker_boot_id="$(nvidia_marker_field boot_id || true)"
        expected_meta="$(nvidia_marker_field meta_package || true)"
        expected_package="$(nvidia_marker_field package_version || true)"
        current_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

        if [[ -n "$marker_boot_id" && "$current_boot_id" == "$marker_boot_id" ]]; then
            STATUS["NVIDIA driver update"]="Waiting for reboot"
            warn "NVIDIA driver packages were updated, but this VM has not rebooted yet"
            show_nvidia_reboot_instructions
            exit 0
        fi

        # Give the NVIDIA stack a short window to become ready after boot.
        while (( attempt < 15 )); do
            running="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
            [[ -n "$running" ]] && break
            sleep 2
            ((attempt+=1))
        done

        if [[ -z "$running" ]]; then
            STATUS["NVIDIA driver update"]="Driver unavailable after reboot"
            error "The VM rebooted, but the NVIDIA driver is not available yet. The reboot marker was kept."
            return 1
        fi

        if [[ -n "$expected_meta" ]]; then
            local installed_after=""
            installed_after="$(installed_version "$expected_meta")"
            write_log INFO "NVIDIA package after reboot: ${expected_meta} ${installed_after:-unknown}"

            if [[ -n "$expected_package" && -n "$installed_after" ]] \
               && dpkg --compare-versions "$installed_after" lt "$expected_package"; then
                STATUS["NVIDIA driver update"]="Package verification failed"
                error "NVIDIA package version after reboot is older than the version recorded by the marker"
                return 1
            fi
        fi

        rm -f "$NVIDIA_REBOOT_MARKER"
        STATUS["Driver"]="$running"
        STATUS["NVIDIA driver update"]="Reboot verified"
        ok "NVIDIA reboot verified; running driver: $running"
        return 0
    fi

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        STATUS["NVIDIA driver update"]="Skipped"
        warn "NVIDIA driver is not available; driver update skipped"
        return 0
    fi

    wait_apt || return 1
    run_long "Refreshing package indexes for NVIDIA" apt-get update || return 1
    APT_INDEX_REFRESHED=1

    local meta=""
    local installed=""
    local candidate=""
    local running_before=""
    local boot_id_before=""
    local updated=""

    meta="$(nvidia_driver_meta_package || true)"

    if [[ -z "$meta" ]]; then
        STATUS["NVIDIA driver update"]="No metapackage"
        warn "NVIDIA driver metapackage could not be detected; the installed driver branch will not be changed automatically"
        return 0
    fi

    installed="$(installed_version "$meta")"
    candidate="$(candidate_version "$meta")"
    running_before="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
    boot_id_before="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

    write_log INFO "NVIDIA metapackage: $meta"
    write_log INFO "NVIDIA installed package version: ${installed:-unknown}"
    write_log INFO "NVIDIA candidate package version: ${candidate:-unknown}"
    write_log INFO "NVIDIA running driver before update: ${running_before:-unknown}"

    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        STATUS["NVIDIA driver update"]="No candidate"
        warn "No NVIDIA driver update candidate is available"
        return 0
    fi

    if [[ -n "$installed" ]] && ! dpkg --compare-versions "$candidate" gt "$installed"; then
        STATUS["NVIDIA driver update"]="Already latest"
        ok "NVIDIA driver package is already latest: $installed"
        return 0
    fi

    # Update the installed NVIDIA branch explicitly. We do not switch from an
    # -open branch to proprietary (or vice versa), and we do not jump branches.
    if ! run_long "Updating NVIDIA driver ($meta)" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "$meta"; then
        STATUS["NVIDIA driver update"]="Failed"
        error "NVIDIA driver update failed"
        return 1
    fi

    wait_apt || true
    env DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$LOG_FILE" 2>&1 || true

    updated="$(installed_version "$meta")"
    STATUS["NVIDIA driver update"]="Updated to ${updated:-$candidate}"
    ok "NVIDIA driver packages updated to ${updated:-$candidate}"

    # Store the boot ID so a second invocation can distinguish a real reboot
    # from simply rerunning the script in the same boot.
    {
        printf 'boot_id=%s\n' "$boot_id_before"
        printf 'meta_package=%s\n' "$meta"
        printf 'package_version=%s\n' "${updated:-$candidate}"
        printf 'driver_before=%s\n' "$running_before"
    } >"$NVIDIA_REBOOT_MARKER"
    chmod 600 "$NVIDIA_REBOOT_MARKER"

    show_nvidia_reboot_instructions
    write_log INFO "Setup stopped intentionally for the required NVIDIA reboot"
    exit 0
}

wait_for_desktop_session() {
    local waited=0
    local timeout=120

    while (( waited < timeout )); do
        if [[ -S "/run/user/${DESKTOP_UID}/bus" ]] \
           && [[ -S /tmp/.X11-unix/X0 || -n "${WAYLAND_DISPLAY:-}" ]]; then
            ok "Desktop session is ready"
            return 0
        fi
        sleep 2
        ((waited+=2))
    done

    warn "Desktop session was not fully ready after ${timeout}s; continuing anyway"
    return 0
}

configure_sunshine_privileges() {
    echo
    echo "========================================="
    echo "Sunshine Performance Privileges"
    echo "========================================="

    local sunshine_bin
    sunshine_bin="$(readlink -f "$(command -v sunshine 2>/dev/null)" 2>/dev/null || true)"

    if [[ -z "$sunshine_bin" || ! -f "$sunshine_bin" ]]; then
        STATUS["Sunshine privileges"]="Missing binary"
        error "Sunshine binary could not be found"
        return 1
    fi

    # Sunshine uses CAP_SYS_NICE for high-priority capture/encoder contexts.
    # CAP_SYS_ADMIN is retained because the native package configures it for
    # Linux capture methods such as KMS. +p matches Sunshine's package setup.
    if ! setcap cap_sys_admin,cap_sys_nice+p "$sunshine_bin" >>"$LOG_FILE" 2>&1; then
        STATUS["Sunshine privileges"]="Failed"
        error "Sunshine capabilities could not be applied"
        return 1
    fi

    local caps
    caps="$(getcap "$sunshine_bin" 2>/dev/null || true)"
    write_log INFO "Sunshine capabilities: ${caps:-none}"

    if grep -q 'cap_sys_nice' <<<"$caps"; then
        STATUS["Sunshine privileges"]="CAP_SYS_NICE enabled"
        ok "Sunshine CAP_SYS_NICE enabled for high-priority streaming"
    else
        STATUS["Sunshine privileges"]="CAP_SYS_NICE missing"
        error "Sunshine CAP_SYS_NICE verification failed"
        return 1
    fi
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

    if command -v nvcc >/dev/null 2>&1; then
        STATUS["CUDA"]="Toolkit available"
        ok "CUDA toolkit detected"
    elif command -v nvidia-smi >/dev/null 2>&1; then
        STATUS["CUDA"]="Driver runtime available"
        ok "CUDA driver runtime available"
    else
        STATUS["CUDA"]="Not detected"
        warn "CUDA not detected"
    fi

    if command -v glxinfo >/dev/null 2>&1 \
       && run_user glxinfo -B >/dev/null 2>&1; then
        STATUS["OpenGL"]="OK"
        ok "OpenGL detected"
    else
        STATUS["OpenGL"]="Not verified"
        warn "OpenGL could not be verified"
    fi

    if command -v pactl >/dev/null 2>&1 \
       && run_user pactl info >/dev/null 2>&1; then
        STATUS["Audio"]="OK"
        ok "Audio service detected"
    else
        STATUS["Audio"]="Not verified"
        warn "Audio service could not be verified"
    fi

    local free_gb
    free_gb="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"
    STATUS["Free space"]="${free_gb:-Unknown} GB"

    if [[ "${free_gb:-0}" =~ ^[0-9]+$ ]] && (( free_gb < 10 )); then
        warn "Less than 10 GB of free disk space is available"
    else
        ok "Free disk space: ${free_gb:-Unknown} GB"
    fi

    for pair in \
        "Lutris:lutris" \
        "Wine:wine" \
        "Sunshine:sunshine" \
        "Tailscale:tailscale"; do

        local label="${pair%%:*}"
        local command_name="${pair##*:}"

        if command -v "$command_name" >/dev/null 2>&1; then
            STATUS["$label"]="Detected"
            ok "$label detected"
        else
            STATUS["$label"]="Missing"
            warn "$label not detected"
        fi
    done
}

# ==============================================================================
# Application installation and updates
# ==============================================================================

normalize_version() {
    local version="${1:-}"

    version="${version#v}"
    version="${version#V}"
    version="${version#lutris-}"
    version="${version#Lutris-}"
    version="${version#MangoHud-}"
    version="${version#mangohud-}"

    # Keep the first numeric dotted version, optionally including a suffix.
    grep -oE '[0-9]+([.][0-9]+){1,3}([~+._-][0-9A-Za-z.-]+)?' \
        <<<"$version" | head -n1
}

github_latest_release_json() {
    local repository="$1"

    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${repository}/releases/latest" \
        2>>"$LOG_FILE"
}

github_release_asset_url() {
    local release_json="$1"
    local asset_regex="$2"

    jq -r --arg regex "$asset_regex" '
        [
            .assets[]
            | select(.name | test($regex; "i"))
        ][0].browser_download_url // empty
    ' <<<"$release_json"
}

install_or_update_lutris_github() {
    local repository="lutris/lutris"
    local release_json=""
    local latest_tag=""
    local latest_version=""
    local installed_raw=""
    local installed_version=""
    local asset_url=""
    local temp_deb="/tmp/lutris-latest.deb"

    info "Checking Lutris version"

    release_json="$(github_latest_release_json "$repository" || true)"

    if [[ -z "$release_json" ]]; then
        write_log WARN "Lutris GitHub release check failed; using APT fallback"
        apt_install_or_update lutris lutris Lutris
        return
    fi

    if [[ "$(jq -r '.prerelease // false' <<<"$release_json")" == "true" \
       || "$(jq -r '.draft // false' <<<"$release_json")" == "true" ]]; then
        write_log WARN "Latest Lutris GitHub release is not stable; using APT fallback"
        apt_install_or_update lutris lutris Lutris
        return
    fi

    latest_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
    latest_version="$(normalize_version "$latest_tag")"
    installed_raw="$(lutris --version 2>/dev/null | head -n1 || true)"
    installed_version="$(normalize_version "$installed_raw")"

    write_log INFO "Lutris installed version: ${installed_version:-not installed}"
    write_log INFO "Lutris latest GitHub version: ${latest_version:-unknown}"

    if [[ -n "$installed_version" && -n "$latest_version" ]] \
       && ! dpkg --compare-versions "$latest_version" gt "$installed_version"; then
        STATUS["Lutris"]="Already latest"
        ok "Lutris is already latest"
        return
    fi

    asset_url="$(github_release_asset_url \
        "$release_json" \
        'lutris.*(_all|all|amd64).*\.deb$|lutris.*\.deb$')"

    if [[ -z "$asset_url" ]]; then
        write_log WARN "No compatible Lutris .deb asset found; using APT fallback"
        apt_install_or_update lutris lutris Lutris
        return
    fi

    if ! run_long "Downloading Lutris ${latest_tag:-latest}" \
        curl -fL --retry 3 "$asset_url" -o "$temp_deb"; then
        STATUS["Lutris"]="Download failed"
        return 1
    fi

    wait_apt || return 1

    if run_long "Installing Lutris ${latest_tag:-latest}" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "$temp_deb"; then

        STATUS["Lutris"]="$(
            [[ -n "$installed_version" ]] && echo Updated || echo Installed
        )"
        rm -f "$temp_deb"
        return 0
    fi

    STATUS["Lutris"]="Install or update failed"
    rm -f "$temp_deb"
    return 1
}

install_or_update_mangohud_github() {
    local repository="flightlessmango/MangoHud"
    local release_json=""
    local latest_tag=""
    local latest_version=""
    local installed_raw=""
    local installed_version=""
    local asset_url=""
    local temp_archive="/tmp/mangohud-latest.tar.gz"
    local temp_dir="/tmp/mangohud-github-release"
    local installer=""

    info "Checking MangoHud version"

    release_json="$(github_latest_release_json "$repository" || true)"

    if [[ -z "$release_json" ]]; then
        write_log WARN "MangoHud GitHub release check failed; using APT fallback"
        apt_install_or_update mangohud mangohud MangoHud
        return
    fi

    if [[ "$(jq -r '.prerelease // false' <<<"$release_json")" == "true" \
       || "$(jq -r '.draft // false' <<<"$release_json")" == "true" ]]; then
        write_log WARN "Latest MangoHud GitHub release is not stable; using APT fallback"
        apt_install_or_update mangohud mangohud MangoHud
        return
    fi

    latest_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
    latest_version="$(normalize_version "$latest_tag")"
    installed_raw="$(mangohud --version 2>/dev/null | head -n1 || true)"
    installed_version="$(normalize_version "$installed_raw")"

    # Ubuntu's older MangoHud package may not support --version reliably.
    if [[ -z "$installed_version" ]]; then
        installed_version="$(normalize_version "$(installed_version mangohud)")"
    fi

    write_log INFO "MangoHud installed version: ${installed_version:-not installed}"
    write_log INFO "MangoHud latest GitHub version: ${latest_version:-unknown}"

    if [[ -n "$installed_version" && -n "$latest_version" ]] \
       && ! dpkg --compare-versions "$latest_version" gt "$installed_version"; then
        STATUS["MangoHud"]="Already latest"
        ok "MangoHud is already latest"
        return
    fi

    asset_url="$(github_release_asset_url \
        "$release_json" \
        '(MangoHud|mangohud).*(x86_64|amd64)?.*\.tar\.(gz|xz)$')"

    if [[ -z "$asset_url" ]]; then
        write_log WARN "No compatible MangoHud release archive found; using APT fallback"
        apt_install_or_update mangohud mangohud MangoHud
        return
    fi

    if ! run_long "Downloading MangoHud ${latest_tag:-latest}" \
        curl -fL --retry 3 "$asset_url" -o "$temp_archive"; then
        STATUS["MangoHud"]="Download failed"
        return 1
    fi

    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    if ! tar -xf "$temp_archive" -C "$temp_dir" >>"$LOG_FILE" 2>&1; then
        STATUS["MangoHud"]="Extraction failed"
        error "MangoHud release archive could not be extracted"
        rm -rf "$temp_dir" "$temp_archive"
        return 1
    fi

    installer="$(find "$temp_dir" -type f -name mangohud-setup.sh | head -n1)"

    if [[ -z "$installer" ]]; then
        STATUS["MangoHud"]="Installer not found"
        error "MangoHud release installer was not found"
        rm -rf "$temp_dir" "$temp_archive"
        return 1
    fi

    chmod +x "$installer"

    if run_long "Installing MangoHud ${latest_tag:-latest}" \
        bash -c 'cd "$1" && ./mangohud-setup.sh install' \
        _ "$(dirname "$installer")"; then

        STATUS["MangoHud"]="$(
            [[ -n "$installed_version" ]] && echo Updated || echo Installed
        )"
        rm -rf "$temp_dir" "$temp_archive"
        return 0
    fi

    STATUS["MangoHud"]="Install or update failed"
    rm -rf "$temp_dir" "$temp_archive"
    return 1
}

install_or_update_discord() {
    local temp_deb="/tmp/discord-latest.deb"
    local installed=""
    local downloaded=""

    if ! run_long "Downloading Discord" \
        curl -fL --retry 3 \
        "https://discord.com/api/download?platform=linux&format=deb" \
        -o "$temp_deb"; then
        STATUS["Discord"]="Download failed"
        return 1
    fi

    downloaded="$(dpkg-deb -f "$temp_deb" Version 2>/dev/null || true)"
    installed="$(installed_version discord)"

    if [[ -n "$installed" && -n "$downloaded" ]] \
       && ! dpkg --compare-versions "$downloaded" gt "$installed"; then
        STATUS["Discord"]="Already latest"
        ok "Discord is already latest"
        rm -f "$temp_deb"
        return 0
    fi

    wait_apt || return 1

    if run_long "Installing Discord" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "$temp_deb"; then
        STATUS["Discord"]="$([[ -n "$installed" ]] && echo Updated || echo Installed)"
        rm -f "$temp_deb"
        return 0
    fi

    STATUS["Discord"]="Install or update failed"
    return 1
}

install_or_update_tailscale() {
    if ! command -v tailscale >/dev/null 2>&1; then
        if ! run_long "Installing Tailscale" \
            bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'; then
            STATUS["Tailscale"]="Install failed"
            return 1
        fi
    fi

    apt-get update >>"$LOG_FILE" 2>&1 || true
    apt_install_or_update tailscale tailscale Tailscale
}

sunshine_asset_url() {
    local release_json="$1"
    local ubuntu_version="${VERSION_ID:-22.04}"

    jq -r --arg version "$ubuntu_version" '
        [
            .assets[]
            | select(
                .name
                | test(
                    "sunshine-ubuntu-" + ($version | gsub("\\."; "\\\\.")) + "-amd64\\.deb$";
                    "i"
                )
            )
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
    local installed_app_version=""

    info "Checking Sunshine version"

    release_json="$(curl -fsSL \
        https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
        2>>"$LOG_FILE" || true)"

    if [[ -z "$release_json" ]]; then
        STATUS["Sunshine"]="Version check failed"
        error "Sunshine release information could not be retrieved"
        return 1
    fi

    latest_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
    asset_url="$(sunshine_asset_url "$release_json")"

    if [[ -z "$asset_url" ]]; then
        STATUS["Sunshine"]="Compatible package not found"
        error "A compatible Sunshine package could not be found"
        return 1
    fi

    if ! run_long "Downloading Sunshine ${latest_tag:-latest}" \
        curl -fL --retry 3 "$asset_url" -o "$temp_deb"; then
        STATUS["Sunshine"]="Download failed"
        return 1
    fi

    downloaded_package_version="$(
        dpkg-deb -f "$temp_deb" Version 2>/dev/null || true
    )"

    installed_package_version="$(
        dpkg-query -W -f='${Version}' sunshine 2>/dev/null || true
    )"

    installed_app_version="$(
        sunshine --version 2>/dev/null | head -n1 || true
    )"

    write_log INFO "Sunshine installed package version: ${installed_package_version:-unknown}"
    write_log INFO "Sunshine installed application version: ${installed_app_version:-unknown}"
    write_log INFO "Sunshine downloaded package version: ${downloaded_package_version:-unknown}"
    write_log INFO "Sunshine latest release tag: ${latest_tag:-unknown}"

    if [[ -n "$installed_package_version" \
       && -n "$downloaded_package_version" ]] \
       && ! dpkg --compare-versions \
            "$downloaded_package_version" gt "$installed_package_version"; then

        STATUS["Sunshine"]="Already latest"
        ok "Sunshine is already latest (${latest_tag:-current})"
        rm -f "$temp_deb"
        return 0
    fi

    wait_apt || return 1

    if run_long "Installing Sunshine ${latest_tag:-latest}" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "$temp_deb"; then

        STATUS["Sunshine"]="$(
            [[ -n "$installed_package_version" ]] && echo Updated || echo Installed
        )"

        rm -f "$temp_deb"
        return 0
    fi

    STATUS["Sunshine"]="Install or update failed"
    return 1
}

install_and_update_applications() {
    echo
    echo "========================================="
    echo "Install and Update Applications"
    echo "========================================="

    wait_apt || return 1

    if (( APT_INDEX_REFRESHED == 0 )); then
        if ! run_long "Updating APT package indexes" apt-get update; then
            error "APT package indexes could not be updated"
            return 1
        fi
        APT_INDEX_REFRESHED=1
    else
        ok "APT package indexes were already refreshed in this run"
    fi

    # Install/update common APT utilities in one transaction. This preserves
    # updates while avoiding repeated dependency resolution and dpkg startup.
    local core_packages=(
        curl wget ca-certificates gnupg jq ffmpeg libcap2-bin
        gamemode nvtop btop vulkan-tools libvulkan1 mesa-utils
        x11-xserver-utils xinput xcvt
    )

    wait_apt || return 1
    if run_long "Installing/updating core gaming utilities" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "${core_packages[@]}"; then
        ok "Core gaming utilities are installed and up to date"
    else
        warn "One or more core utilities could not be updated"
    fi

    # run_long waits for apt/dpkg to exit. This extra settle step repairs any
    # interrupted configuration before application-specific updates continue.
    wait_apt || return 1
    env DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$LOG_FILE" 2>&1 || true

    # Essential gaming tools and applications keep their version-aware updates.
    install_or_update_mangohud_github || true
    apt_install_or_update steam-installer steam Steam || true
    install_or_update_lutris_github || true

    if dpkg -s winehq-staging >/dev/null 2>&1; then
        apt_install_or_update winehq-staging wine "Wine Staging" || true
        STATUS["Wine"]="${STATUS["Wine Staging"]:-Installed}"
    elif dpkg -s wine-staging >/dev/null 2>&1; then
        apt_install_or_update wine-staging wine "Wine Staging" || true
        STATUS["Wine"]="${STATUS["Wine Staging"]:-Installed}"
    else
        apt_install_or_update wine wine Wine || true
    fi

    apt_install_or_update firefox firefox Firefox || true
    apt_install_or_update google-chrome-stable google-chrome "Google Chrome" || true

    install_or_update_discord || true
    flatpak_install_or_update net.davidotek.pupgui2 ProtonUp-Qt || true
    install_or_update_tailscale || true
    install_or_update_sunshine || true

    wait_apt || true
    env DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
}

# ==============================================================================
# Tailscale
# ==============================================================================

configure_tailscale() {
    echo
    echo "========================================="
    echo "Configure Tailscale"
    echo "========================================="

    if ! command -v tailscale >/dev/null 2>&1; then
        STATUS["Tailscale"]="Missing"
        error "Tailscale is not installed"
        return 1
    fi

    if ! systemctl enable --now tailscaled >>"$LOG_FILE" 2>&1; then
        warn "The tailscaled service could not be enabled automatically"
    fi

    if ! tailscale status >/dev/null 2>&1; then
        if [[ -t 0 ]]; then
            echo
            tailscale up 2>&1 | tee -a "$LOG_FILE" || true
        else
            warn "Tailscale requires an interactive login"
        fi
    fi

    if tailscale status >/dev/null 2>&1; then
        TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
        SUNSHINE_URL="https://${TAILSCALE_IP}:47990"
        STATUS["Tailscale"]="Connected"

        ok "Tailscale connected"
        echo
        echo "Connected"
        echo
        echo "IP:"
        echo "$TAILSCALE_IP"
    else
        STATUS["Tailscale"]="Not connected"
        warn "Tailscale is not connected"
    fi
}

# ==============================================================================
# Sunshine
# ==============================================================================

find_sunshine_service() {
    local service

    for service in \
        app-dev.lizardbyte.app.Sunshine.service \
        sunshine.service; do

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
        sed -i -E \
            "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" \
            "$config_file"
    else
        printf '%s = %s\n' "$key" "$value" >>"$config_file"
    fi
}

configure_sunshine() {
    echo
    echo "========================================="
    echo "Configure Sunshine"
    echo "========================================="

    if ! command -v sunshine >/dev/null 2>&1; then
        STATUS["Sunshine"]="Missing"
        error "Sunshine is not installed"
        return 1
    fi

    local config_dir
    local config_file
    local service

    config_dir="${DESKTOP_HOME}/.config/sunshine"
    config_file="${config_dir}/sunshine.conf"

    if ! install -d -m 700 \
        -o "$DESKTOP_USER" \
        -g "$DESKTOP_GROUP" \
        "$config_dir"; then
        error "Sunshine configuration directory could not be created"
        return 1
    fi

    if ! touch "$config_file"; then
        error "Sunshine configuration file could not be created"
        return 1
    fi

    if ! chown "$DESKTOP_USER:$DESKTOP_GROUP" "$config_file"; then
        error "Sunshine configuration ownership could not be set"
        return 1
    fi

    chmod 600 "$config_file" || true

    # Remove any capture override left from previous troubleshooting so Sunshine
    # can choose the best supported capture method automatically.
    sed -i -E '/^[[:space:]]*capture[[:space:]]*=/d' "$config_file"

    set_sunshine_option "$config_file" encoder nvenc
    set_sunshine_option "$config_file" upnp disabled

    if [[ "$TAILSCALE_IP" != "Not connected" ]]; then
        set_sunshine_option "$config_file" origin_web_ui_allowed wan
        set_sunshine_option \
            "$config_file" \
            csrf_allowed_origins \
            "https://${TAILSCALE_IP}:47990"
    fi

    chown "$DESKTOP_USER:$DESKTOP_GROUP" "$config_file" || \
        error "Sunshine configuration ownership could not be restored"

    service="$(find_sunshine_service || true)"

    if [[ -z "$service" ]]; then
        STATUS["Sunshine"]="Service not found"
        error "The Sunshine user service could not be found"
        return 1
    fi

    # Stop both the managed service and any manually started stale Sunshine
    # process, then restore the capabilities before starting one clean instance.
    systemctl --machine="${DESKTOP_USER}@.host" --user \
        stop "$service" >>"$LOG_FILE" 2>&1 || true
    pkill -TERM -x sunshine >>"$LOG_FILE" 2>&1 || true
    sleep 1
    pkill -KILL -x sunshine >>"$LOG_FILE" 2>&1 || true

    configure_sunshine_privileges || true

    systemctl --machine="${DESKTOP_USER}@.host" --user daemon-reload \
        >>"$LOG_FILE" 2>&1 || true

    if systemctl --machine="${DESKTOP_USER}@.host" --user \
        enable --now "$service" >>"$LOG_FILE" 2>&1; then
        STATUS["Sunshine"]="Running"
        ok "Sunshine service is running"
    else
        STATUS["Sunshine"]="Service failed"
        error "Sunshine service could not be started"
        return 1
    fi

    local attempt
    local port_ready=0

    for attempt in {1..12}; do
        if ss -ltn 2>/dev/null | grep -qE ':47990[[:space:]]'; then
            port_ready=1
            break
        fi
        sleep 1
    done

    if (( port_ready == 1 )); then
        ok "Sunshine Web UI port 47990 is listening"
    else
        warn "Sunshine Web UI port 47990 is not listening yet"
    fi
}


# ============================================================================== 
# Host gaming optimizations
# ============================================================================== 

configure_host_optimizations() {
    echo
    echo "========================================="
    echo "Host Gaming Optimizations"
    echo "========================================="

    local governor_file
    local governor_changed=0

    for governor_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -e "$governor_file" ]] || continue
        if grep -qw performance "${governor_file%/*}/scaling_available_governors" 2>/dev/null; then
            if printf '%s' performance >"$governor_file" 2>>"$LOG_FILE"; then
                governor_changed=1
            fi
        fi
    done

    if (( governor_changed == 1 )); then
        STATUS["CPU governor"]="Performance"
        ok "CPU governor set to performance"
    else
        STATUS["CPU governor"]="Not exposed by VM"
        info "CPU governor control is not exposed by this VM"
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi -pm 1 >>"$LOG_FILE" 2>&1; then
            STATUS["NVIDIA persistence"]="Enabled"
            ok "NVIDIA persistence mode enabled"
        else
            STATUS["NVIDIA persistence"]="Not supported"
            info "NVIDIA persistence mode is controlled by the host"
        fi
    fi

    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
        local route_state
        route_state="$(tailscale status --json 2>/dev/null | jq -r '
            [.Peer[]? | select(.Online == true)] as $p
            | if ($p | length) == 0 then "No online peer"
              elif any($p[]; (.CurAddr // "") != "") then "Direct peer available"
              else "Relay or unknown"
              end
        ' 2>/dev/null || true)"
        [[ -n "$route_state" ]] && info "Tailscale connection check: $route_state"
    fi
}

# ==============================================================================
# KDE desktop
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

    if [[ -z "$source_file" ]]; then
        warn "Desktop shortcut source not found for $label"
        return 1
    fi

    if ! cp "$source_file" "$destination"; then
        error "$label desktop shortcut could not be copied"
        return 1
    fi

    if ! chown "$DESKTOP_USER:$DESKTOP_GROUP" "$destination"; then
        error "$label desktop shortcut ownership could not be set"
        return 1
    fi

    chmod +x "$destination" || true
    ok "$label desktop shortcut created"
}


apply_wallpaper() {
    local wallpaper_dir="/usr/share/wallpapers/Linux-Gaming-VM"
    local wallpaper_file="${wallpaper_dir}/wallpaper.jpg"
    local qdbus_command=""

    mkdir -p "$wallpaper_dir" >>"$LOG_FILE" 2>&1 || return 0

    base64 -d >"$wallpaper_file" <<'LINUX_GAMING_VM_WALLPAPER'
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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAlggQg7fW9QoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAlgICEIE7J2eYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAICIIhr1OHsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQEsBBmwcvF6hsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAIQQJLyHY7YAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQASwhBLCen1+6AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAEECEGseic1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADzQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAEBJYIpzehnQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIBLBAksJ3+t6RKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQBAQRAndOxsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAIEIIHJ6XHygAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgEsEQSwnb6/qFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEACEEQS852ecAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAIEIIhfV4OyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABASwQJLBy8XpnIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADzQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAgBJcljZ2e3KAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAQEQRB6XX7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEsBAQRBrHoHNoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAIElhAc/oY2AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACASwRBLCd7r+kAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABLkoIQRBHcOxySgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAECEEQ5PT4uYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA80AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAlggSWE7XX9Q0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADzQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAgBJYSXmOz2AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA80AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAgQgiF9Tg7QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAQSwhBycXpnKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADzQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJYAIglhJdnP3ZQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADzQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQCAiCWE9Lrd8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA80AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAICCBLn0Dm0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAICSwko5vQzsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA80AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAlglhIg7vW9MoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgCAggSO2djlAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADzQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACACBJYIhv1OLmAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABACCBIDscHqGgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABLAQEECS8p2eyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgEBEEB6nX7YAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBLBLBEG8ekcoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAQElhJadjvSgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgEBLkRB6PW9AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBHCMCJACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAECOBICFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBNMEDAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBNBOJAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABPEPLECAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEJAJCJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHLCNBAFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANEPEMCAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFIPJMBIEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIILDAGCJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEOCGCDBACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFMKMHMCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANKCOKEAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAHFGBAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJFPBIGAJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEPBHJECAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEHIODICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGLFNCBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADCMOBKACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALHJGKGAJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJALFHBAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALKJICBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOFJEJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOGFOBIEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJPKFLCAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFCAFCBACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEILMBMABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMNKFBACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEKNMCJCFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANEMHMGAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEDKAPCKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIIPEDOCBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANLHAGAAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEPMKMJAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANKGCAGAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEHEJDBJEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALLBJDAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFDCJCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAELKGMJCEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKJKDAHAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADNDGJAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMCFCDGAJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEKLBPCJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFFCGJECAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFBHMMCAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABLNCNJAECAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADNCLGCJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEGGOAEJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFFIMIMCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHAAOMEAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFEEMCAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKPDBMCBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACFOAHJACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANCHOAOABADAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHNMNKIMHDGLPHDECAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBMIMLAAD7X8m7EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANJKEJuYHIXigKTIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAEOTEw40y73fYLQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAA1aQQAAFDaHOrnBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBAe2e4CQAAAnyNJwwJCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEFMNCBNAELGMCTFn/fKCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGBBDOIJACLBHLAOF/RBCAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABACJDAAAJAIDCGFEPPOLGEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAGIPAAAAEMAAAAIGMAABIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABJBPAKAAAAAAAAAABDDBAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAICDDGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIFKIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAKMNCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIEDMOAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGBBKLIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABACIFKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEGIDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBJLCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAHMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAEGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAJOMIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIAJMMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGBGLHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAIEAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIEGAOIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBIDCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABACAGEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIEHNKIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGABLBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABICLDMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACEGPHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIBAKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIGDCOAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABADDIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAEJIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIEHMMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFABKGKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIAIDOAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFGMLAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIAMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIGLHMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKAEKHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEABMMKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIGDMCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGBBACIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIIMPMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAPPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBICOIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAPGIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKAGOAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBBOJAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIKCCBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACFEBFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIMNIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIGBHIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBMDCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABABMAOAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKCGKFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBBBGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAKAHCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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
LINUX_GAMING_VM_WALLPAPER

    chmod 644 "$wallpaper_file" >>"$LOG_FILE" 2>&1 || true

    if command -v qdbus >/dev/null 2>&1; then
        qdbus_command="qdbus"
    elif command -v qdbus-qt5 >/dev/null 2>&1; then
        qdbus_command="qdbus-qt5"
    else
        write_log INFO "Wallpaper was extracted, but qdbus is unavailable"
        return 0
    fi

    local plasma_script
    plasma_script="var ds = desktops(); for (var i = 0; i < ds.length; i++) { ds[i].wallpaperPlugin = 'org.kde.image'; ds[i].currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General']; ds[i].writeConfig('Image', 'file://$wallpaper_file'); }"

    if run_user "$qdbus_command" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript "$plasma_script" \
        >>"$LOG_FILE" 2>&1; then
        write_log OK "Wallpaper applied"
    else
        write_log WARN "Wallpaper could not be applied automatically"
    fi
}

configure_mouse_acceleration() {
    echo
    echo "========================================="
    echo "Mouse Acceleration"
    echo "========================================="
    echo
    echo "[1] Disable"
    echo "[2] Keep Current Setting"
    echo
    echo "Choice:"

    if [[ ! -t 0 ]]; then
        write_log INFO "Mouse acceleration setting kept because no interactive terminal was detected"
        return 0
    fi

    local choice
    while read -r choice; do
        case "$choice" in
            1)
                if ! command -v xinput >/dev/null 2>&1; then
                    warn "Mouse acceleration could not be changed because xinput is unavailable"
                    return 0
                fi

                local changed=0
                local device_id
                while read -r device_id; do
                    [[ -n "$device_id" ]] || continue
                    if run_user xinput list-props "$device_id" 2>/dev/null \
                        | grep -q "libinput Accel Profile Enabled"; then
                        if run_user xinput set-prop "$device_id" \
                            "libinput Accel Profile Enabled" 0 1 0 \
                            >>"$LOG_FILE" 2>&1; then
                            changed=1
                        fi
                    fi
                done < <(run_user xinput list --id-only 2>/dev/null || true)

                if (( changed == 1 )); then
                    ok "Mouse acceleration disabled for the current session"
                else
                    warn "No compatible libinput pointer device was found"
                fi
                break
                ;;
            2)
                ok "Mouse acceleration setting kept"
                break
                ;;
            *)
                echo "Invalid choice. Enter 1 or 2:"
                ;;
        esac
    done
}

create_optional_shortcut() {
    local label="$1"
    shift

    local source_file
    local destination

    source_file="$(find_desktop_file "$@" || true)"
    destination="${DESKTOP_HOME}/Desktop/${label}.desktop"

    if [[ -z "$source_file" ]]; then
        write_log INFO "Optional desktop shortcut source not found for $label"
        return 0
    fi

    if ! cp "$source_file" "$destination"; then
        write_log WARN "$label desktop shortcut could not be copied"
        return 0
    fi

    if ! chown "$DESKTOP_USER:$DESKTOP_GROUP" "$destination"; then
        write_log WARN "$label desktop shortcut ownership could not be set"
        return 0
    fi

    chmod +x "$destination" || true
    ok "$label desktop shortcut created"
}

configure_desktop() {
    echo
    echo "========================================="
    echo "Configure Desktop"
    echo "========================================="

    if ! install -d -m 755 \
        -o "$DESKTOP_USER" \
        -g "$DESKTOP_GROUP" \
        "${DESKTOP_HOME}/Desktop"; then
        error "Desktop directory could not be prepared"
        return 1
    fi

    if command -v lookandfeeltool >/dev/null 2>&1 \
       && run_user lookandfeeltool -a org.kde.breezedark.desktop \
            >>"$LOG_FILE" 2>&1; then
        STATUS["Theme"]="Dark"
        ok "KDE dark theme applied"
    else
        STATUS["Theme"]="Not applied"
        warn "KDE dark theme could not be applied"
    fi

    apply_wallpaper

    create_shortcut Steam \
        steam.desktop \
        com.valvesoftware.Steam.desktop || true

    create_shortcut "Google Chrome" \
        google-chrome.desktop \
        'google-chrome*.desktop' || true

    create_shortcut Firefox \
        firefox.desktop \
        org.mozilla.firefox.desktop || true

    create_shortcut Lutris \
        net.lutris.Lutris.desktop \
        lutris.desktop || true

    create_optional_shortcut Discord \
        discord.desktop \
        Discord.desktop \
        com.discordapp.Discord.desktop \
        com.discordapp.discord.desktop \
        "*discord*.desktop" || true

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
Comment=Open the Sunshine web interface
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

    if chown "$DESKTOP_USER:$DESKTOP_GROUP" \
        "$sunshine_shortcut" "$trash_shortcut"; then
        chmod +x "$sunshine_shortcut" "$trash_shortcut" || true
        ok "Sunshine Web UI and Trash shortcuts created"
    else
        error "Desktop shortcut ownership could not be set"
    fi
}

# ==============================================================================
# Display
# ==============================================================================

primary_output() {
    run_user xrandr --query 2>/dev/null \
        | awk '
            / connected primary / {print $1; exit}
            / connected / && !fallback {fallback=$1}
            END {if (fallback) print fallback}
        ' \
        | head -n1
}

current_resolution() {
    run_user xrandr --current 2>/dev/null \
        | awk '
            / connected / {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^[0-9]+x[0-9]+\+/) {
                        split($i, a, "+")
                        print a[1]
                        exit
                    }
                }
            }
        '
}

current_refresh() {
    run_user xrandr --current 2>/dev/null \
        | awk '
            /\*/ {
                value=$2
                gsub(/[^0-9.]/, "", value)
                print value
                exit
            }
        '
}

choose_resolution() {
    cat <<'EOF'

=========================================
Choose Display Resolution
=========================================

4:3
[1] 1024x768

16:9
[2] 1280x720
[3] 1366x768
[4] 1600x900
[5] 1920x1080
[6] 2560x1440
[7] 3840x2160

Ultrawide
[8] 2560x1080
[9] 3440x1440

[10] Keep Current Resolution

Choice:
EOF

    if [[ ! -t 0 ]]; then
        RESOLUTION="$(current_resolution || echo "Keep current")"
        warn "No interactive terminal detected; keeping the current resolution"
        return
    fi

    local choice

    while read -r choice; do
        case "$choice" in
            1) RESOLUTION="1024x768" ;;
            2) RESOLUTION="1280x720" ;;
            3) RESOLUTION="1366x768" ;;
            4) RESOLUTION="1600x900" ;;
            5) RESOLUTION="1920x1080" ;;
            6) RESOLUTION="2560x1440" ;;
            7) RESOLUTION="3840x2160" ;;
            8) RESOLUTION="2560x1080" ;;
            9) RESOLUTION="3440x1440" ;;
            10) RESOLUTION="$(current_resolution || echo "Keep current")" ;;
            *)
                echo "Invalid choice. Enter a number from 1 to 10:"
                continue
                ;;
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
[2] 75 Hz
[3] 90 Hz
[4] 120 Hz
[5] 144 Hz
[6] 165 Hz
[7] 240 Hz

[8] Keep Current Refresh Rate

Choice:
EOF

    if [[ ! -t 0 ]]; then
        REFRESH_RATE="$(current_refresh || echo "Keep current")"
        warn "No interactive terminal detected; keeping the current refresh rate"
        return
    fi

    local choice

    while read -r choice; do
        case "$choice" in
            1) REFRESH_RATE="60" ;;
            2) REFRESH_RATE="75" ;;
            3) REFRESH_RATE="90" ;;
            4) REFRESH_RATE="120" ;;
            5) REFRESH_RATE="144" ;;
            6) REFRESH_RATE="165" ;;
            7) REFRESH_RATE="240" ;;
            8) REFRESH_RATE="$(current_refresh || echo "Keep current")" ;;
            *)
                echo "Invalid choice. Enter a number from 1 to 8:"
                continue
                ;;
        esac
        break
    done
}

apply_display() {
    local output
    local width
    local height
    local modeline
    local mode_name

    output="$(primary_output)"

    if [[ -z "$output" ]]; then
        error "No connected X11 display output was detected"
        return 1
    fi

    if run_user xrandr \
        --output "$output" \
        --mode "$RESOLUTION" \
        --rate "$REFRESH_RATE" \
        >>"$LOG_FILE" 2>&1; then

        ok "Display set to $RESOLUTION at $REFRESH_RATE Hz"
        return 0
    fi

    width="${RESOLUTION%x*}"
    height="${RESOLUTION#*x}"

    modeline="$(
        cvt "$width" "$height" "$REFRESH_RATE" 2>/dev/null \
        | awk '/Modeline/ {$1=""; sub(/^ /, ""); print}'
    )"

    if [[ -z "$modeline" ]]; then
        error "A modeline for $RESOLUTION at $REFRESH_RATE Hz could not be generated"
        return 1
    fi

    mode_name="$(awk '{gsub(/"/, "", $1); print $1}' <<<"$modeline")"

    # Word splitting is intentional for the generated xrandr modeline.
    # shellcheck disable=SC2086
    run_user xrandr --newmode $modeline >>"$LOG_FILE" 2>&1 || true
    run_user xrandr --addmode "$output" "$mode_name" >>"$LOG_FILE" 2>&1 || true

    if run_user xrandr \
        --output "$output" \
        --mode "$mode_name" \
        >>"$LOG_FILE" 2>&1; then

        ok "Display set to $RESOLUTION at $REFRESH_RATE Hz"
        return 0
    fi

    error "Display configuration failed"
    return 1
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

    if [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ \
       && "$REFRESH_RATE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        apply_display || true
    else
        warn "Display configuration was kept unchanged"
    fi

    STATUS["Resolution"]="$RESOLUTION"
    STATUS["Refresh rate"]="${REFRESH_RATE} Hz"
}

# ==============================================================================
# Final verification
# ==============================================================================

verify_vulkan_final() {
    if command -v vulkaninfo >/dev/null 2>&1 \
       && run_user vulkaninfo --summary >/dev/null 2>&1; then
        STATUS["Vulkan"]="OK"
        ok "Vulkan verified"
    else
        STATUS["Vulkan"]="Failed"
        warn "Vulkan verification failed"
    fi
}

verify_nvenc_final() {
    if command -v ffmpeg >/dev/null 2>&1 \
       && ffmpeg -hide_banner -encoders 2>/dev/null \
            | grep -qE 'h264_nvenc|hevc_nvenc|av1_nvenc'; then
        STATUS["NVENC"]="OK"
        ok "NVENC verified"
    elif ldconfig -p 2>/dev/null | grep -q 'libnvidia-encode.so.1'; then
        STATUS["NVENC"]="Available"
        info "NVENC library detected; runtime encoding will be verified by Sunshine"
    else
        STATUS["NVENC"]="Not verified"
        info "NVENC could not be verified automatically"
    fi
}

verify_app_final() {
    local label="$1"
    local command_name="$2"

    if [[ "$label" == "Steam" ]] \
       && { dpkg -s steam-installer >/dev/null 2>&1 \
            || [[ -x /usr/games/steam ]] \
            || command -v steam >/dev/null 2>&1; }; then
        STATUS["$label"]="OK"
    elif command -v "$command_name" >/dev/null 2>&1; then
        STATUS["$label"]="OK"
    elif [[ "${STATUS[$label]:-}" == "Install failed" \
         || "${STATUS[$label]:-}" == "Update failed" \
         || "${STATUS[$label]:-}" == "Install or update failed" ]]; then
        :
    else
        STATUS["$label"]="Missing"
    fi
}

final_verification() {
    echo
    echo "========================================="
    echo "Final Verification"
    echo "========================================="

    verify_vulkan_final
    verify_nvenc_final

    if command -v glxinfo >/dev/null 2>&1 \
       && run_user glxinfo -B >/dev/null 2>&1; then
        STATUS["OpenGL"]="OK"
        ok "OpenGL verified"
    else
        STATUS["OpenGL"]="Failed"
        warn "OpenGL verification failed"
    fi

    verify_app_final Steam steam
    verify_app_final "Google Chrome" google-chrome
    verify_app_final Firefox firefox
    verify_app_final Discord discord
    verify_app_final Lutris lutris
    verify_app_final Wine wine
    verify_app_final Sunshine sunshine
    verify_app_final Tailscale tailscale

    if tailscale status >/dev/null 2>&1; then
        STATUS["Tailscale"]="Connected"
        TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
        SUNSHINE_URL="https://${TAILSCALE_IP}:47990"
        ok "Tailscale verified"
    else
        STATUS["Tailscale"]="Not connected"
        warn "Tailscale is not connected"
    fi

    local service
    service="$(find_sunshine_service || true)"

    if [[ -n "$service" ]] \
       && systemctl --machine="${DESKTOP_USER}@.host" --user \
            is-active --quiet "$service"; then
        STATUS["Sunshine"]="Running"
        ok "Sunshine service verified"
    else
        STATUS["Sunshine"]="Not running"
        warn "Sunshine service is not running"
    fi

    if ss -ltn 2>/dev/null | grep -qE ':47990[[:space:]]'; then
        STATUS["Sunshine port"]="Listening"
        ok "Sunshine Web UI port verified"
    else
        STATUS["Sunshine port"]="Not listening"
        warn "Sunshine Web UI port is not listening"
    fi
}

# ==============================================================================
# Cleanup and summary
# ==============================================================================

cleanup() {
    echo
    echo "========================================="
    echo "Cleanup"
    echo "========================================="

    wait_apt || return 1

    run_long "Removing unused packages" \
        env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true

    run_long "Cleaning APT cache" apt-get autoclean || true

    rm -f \
        /tmp/discord-latest.deb \
        /tmp/lutris-latest.deb \
        /tmp/mangohud-latest.tar.gz \
        /tmp/sunshine-latest.deb

    rm -rf /tmp/mangohud-github-release
}

copy_support_log() {
    local support_dir

    support_dir="$(dirname "$SUPPORT_LOG")"

    mkdir -p "$support_dir"
    cp "$LOG_FILE" "$SUPPORT_LOG"

    chown -R "$DESKTOP_USER:$DESKTOP_GROUP" \
        "${DESKTOP_HOME}/.local/share/.linux-gaming-vm"

    chmod 700 "${DESKTOP_HOME}/.local/share/.linux-gaming-vm"
    chmod 600 "$SUPPORT_LOG"
}

value() {
    local key="$1"
    printf '%s' "${STATUS[$key]:-Not detected}"
}

summary() {
    echo
    echo "========================================="
    echo "Linux-Gaming-VM Summary"
    echo "========================================="
    echo
    echo "System"
    echo "-------------------------"
    printf '%-18s %s\n' "GPU.............." "$(value GPU)"
    printf '%-18s %s\n' "Driver..........." "$(value Driver)"
    printf '%-18s %s\n' "Driver update...." "$(value "NVIDIA driver update")"
    printf '%-18s %s\n' "CUDA............." "$(value CUDA)"
    printf '%-18s %s\n' "NVENC............" "$(value NVENC)"
    printf '%-18s %s\n' "OpenGL..........." "$(value OpenGL)"
    printf '%-18s %s\n' "Vulkan..........." "$(value Vulkan)"
    echo
    echo "Applications"
    echo "-------------------------"
    printf '%-18s %s\n' "Steam............" "$(value Steam)"
    printf '%-18s %s\n' "Chrome..........." "$(value "Google Chrome")"
    printf '%-18s %s\n' "Firefox.........." "$(value Firefox)"
    printf '%-18s %s\n' "Discord.........." "$(value Discord)"
    printf '%-18s %s\n' "Lutris..........." "$(value Lutris)"
    printf '%-18s %s\n' "Wine............." "$(value Wine)"
    printf '%-18s %s\n' "Sunshine........." "$(value Sunshine)"
    printf '%-18s %s\n' "Sunshine nice...." "$(value "Sunshine privileges")"
    printf '%-18s %s\n' "Selkies/WebRTC..." "$(value Selkies)"
    printf '%-18s %s\n' "Tailscale........" "$(value Tailscale)"
    echo
    echo "Desktop"
    echo "-------------------------"
    printf '%-18s %s\n' "Theme............" "$(value Theme)"
    printf '%-18s %s\n' "Resolution......." "$(value Resolution)"
    printf '%-18s %s\n' "Refresh Rate....." "$(value "Refresh rate")"
    echo
    echo "Network"
    echo "-------------------------"
    printf '%-18s %s\n' "Tailscale IP....." "$TAILSCALE_IP"
    printf '%-18s %s\n' "Sunshine Web....." "$SUNSHINE_URL"
    echo

    echo "Finished with $ERRORS Error(s) and $WARNINGS Warning(s)"

    if (( ERRORS + WARNINGS > 0 )); then
        echo "A diagnostic log was generated for troubleshooting."
    fi

    echo "========================================="

    write_log INFO \
        "Finished with $ERRORS error(s) and $WARNINGS warning(s)"

    copy_support_log || true
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    require_root

    # Refuse to make system changes if the downloaded script is malformed or
    # contains the known Sunshine/set -u regression.
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
    install_and_update_applications

    wait_for_desktop_session
    configure_tailscale
    configure_sunshine
    configure_host_optimizations
    configure_desktop
    configure_mouse_acceleration
    configure_display
    final_verification
    cleanup
    summary
}

if [[ "${1:-}" == "--self-check" ]]; then
    self_check_script
    exit $?
fi

if [[ "${1:-}" == "--version" ]]; then
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION} (${SCRIPT_BUILD})"
    exit 0
fi

main "$@"
