#!/usr/bin/env bash
# Linux-Gaming-VM v1.0
# Designed for Vast.ai KVM virtual machines running Ubuntu/KDE Plasma.

set -u
set -o pipefail

SCRIPT_NAME="Linux-Gaming-VM"
SCRIPT_VERSION="1.0"
LOG_DIR="/var/lib/.linux-gaming-vm"
LOG_FILE="$LOG_DIR/linux-gaming-vm.log"

ERRORS=0
WARNINGS=0
DESKTOP_USER=""
DESKTOP_HOME=""
DESKTOP_UID=""
DISPLAY_VALUE="${DISPLAY:-:0}"
XAUTHORITY_VALUE=""
TAILSCALE_IP="Not connected"
SUNSHINE_URL="Unavailable"
RESOLUTION="Keep current"
REFRESH_RATE="Keep current"

declare -A STATUS

if [[ -t 1 ]]; then
  RESET=$'\033[0m'; BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'
else
  RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

init_log() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  printf '\n%s [%s] %s %s started\n' "$(date '+%F %T')" INFO "$SCRIPT_NAME" "$SCRIPT_VERSION" >>"$LOG_FILE"
}

write_log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE"; }
info() { printf '%s[INFO]%s  %s\n' "$BLUE" "$RESET" "$*"; write_log INFO "$*"; }
ok() { printf '%s[ OK ]%s  %s\n' "$GREEN" "$RESET" "$*"; write_log OK "$*"; }
warn() { printf '%s[WARN]%s  %s\n' "$YELLOW" "$RESET" "$*"; write_log WARN "$*"; ((WARNINGS++)) || true; }
error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*"; write_log ERROR "$*"; ((ERRORS++)) || true; }

run_logged() {
  local description="$1"; shift
  info "$description"
  write_log COMMAND "$*"
  if "$@" >>"$LOG_FILE" 2>&1; then ok "$description"; return 0; fi
  local rc=$?
  write_log ERROR "Exit code $rc"
  error "$description failed"
  return "$rc"
}

run_user() {
  sudo -u "$DESKTOP_USER" env \
    HOME="$DESKTOP_HOME" USER="$DESKTOP_USER" LOGNAME="$DESKTOP_USER" \
    DISPLAY="$DISPLAY_VALUE" XAUTHORITY="$XAUTHORITY_VALUE" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DESKTOP_UID/bus" "$@"
}

banner() {
  clear 2>/dev/null || true
  cat <<'EOF'
=========================================
Linux-Gaming-VM
Version 1.0
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

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run with: sudo bash $0"
    exit 1
  fi
}

detect_environment() {
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || { error "Ubuntu is required."; exit 1; }
  STATUS["Operating system"]="${PRETTY_NAME:-Ubuntu}"

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    DESKTOP_USER="$SUDO_USER"
  else
    DESKTOP_USER="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3!="root"{print $3;exit}')"
    [[ -n "$DESKTOP_USER" ]] || DESKTOP_USER="$(getent passwd 1000 | cut -d: -f1)"
  fi

  id "$DESKTOP_USER" >/dev/null 2>&1 || { error "Desktop user not found."; exit 1; }
  DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
  DESKTOP_UID="$(id -u "$DESKTOP_USER")"
  XAUTHORITY_VALUE="$DESKTOP_HOME/.Xauthority"
  [[ -f "/run/user/$DESKTOP_UID/gdm/Xauthority" ]] && XAUTHORITY_VALUE="/run/user/$DESKTOP_UID/gdm/Xauthority"
  STATUS["Desktop user"]="$DESKTOP_USER"
  ok "Desktop user detected: $DESKTOP_USER"
}

wait_apt() {
  local seconds=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 ||
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    ((seconds==0)) && warn "APT is busy. Waiting..."
    ((seconds>=900)) && { error "APT remained locked for 15 minutes."; return 1; }
    sleep 5; ((seconds+=5))
  done
}

verify_system() {
  echo; echo "========================================="; echo "Verify System"; echo "========================================="

  curl -fsS --max-time 10 https://tailscale.com >/dev/null 2>&1 &&
    { STATUS["Internet"]="OK"; ok "Internet connection available"; } ||
    { STATUS["Internet"]="Failed"; error "Internet connection failed"; }

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    STATUS["GPU"]="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)"
    STATUS["Driver"]="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
    ok "NVIDIA GPU detected: ${STATUS["GPU"]}"
  else
    STATUS["GPU"]="Not detected"; STATUS["Driver"]="Not detected"; error "NVIDIA GPU not detected"
  fi

  command -v nvcc >/dev/null 2>&1 && STATUS["CUDA"]="OK" || STATUS["CUDA"]="Driver runtime only"
  command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary >/dev/null 2>&1 &&
    { STATUS["Vulkan"]="OK"; ok "Vulkan detected"; } ||
    { STATUS["Vulkan"]="Not verified"; warn "Vulkan not verified"; }
  command -v glxinfo >/dev/null 2>&1 && run_user glxinfo -B >/dev/null 2>&1 &&
    { STATUS["OpenGL"]="OK"; ok "OpenGL detected"; } ||
    { STATUS["OpenGL"]="Not verified"; warn "OpenGL not verified"; }
  command -v ffmpeg >/dev/null 2>&1 && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc &&
    { STATUS["NVENC"]="OK"; ok "NVENC detected"; } ||
    { STATUS["NVENC"]="Not verified"; warn "NVENC not verified"; }

  for pair in "Steam:steam" "Lutris:lutris" "Wine:wine" "Sunshine:sunshine" "Tailscale:tailscale"; do
    local label="${pair%%:*}" cmd="${pair##*:}"
    command -v "$cmd" >/dev/null 2>&1 && { STATUS["$label"]="Installed"; ok "$label detected"; } ||
      { STATUS["$label"]="Missing"; warn "$label not detected"; }
  done
}

apt_install() {
  local package="$1" command_name="${2:-$1}" label="${3:-$1}"
  if command -v "$command_name" >/dev/null 2>&1 || dpkg -s "$package" >/dev/null 2>&1; then
    STATUS["$label"]="Installed"; ok "$label is already installed"; return 0
  fi
  wait_apt || return 1
  if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >>"$LOG_FILE" 2>&1; then
    STATUS["$label"]="Installed"; ok "$label installed"; return 0
  fi
  STATUS["$label"]="Install failed"; error "$label installation failed"; return 1
}

install_deb() {
  local label="$1" url="$2" file="$3" command_name="$4"
  command -v "$command_name" >/dev/null 2>&1 && { STATUS["$label"]="Installed"; ok "$label is already installed"; return 0; }
  info "Downloading $label"
  curl -fL --retry 3 "$url" -o "$file" >>"$LOG_FILE" 2>&1 || { error "$label download failed"; return 1; }
  wait_apt || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$file" >>"$LOG_FILE" 2>&1 &&
    { STATUS["$label"]="Installed"; ok "$label installed"; rm -f "$file"; return 0; }
  error "$label installation failed"; return 1
}

ensure_flatpak() {
  apt_install flatpak flatpak Flatpak || return 1
  flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >>"$LOG_FILE" 2>&1
}

install_flatpak() {
  local app="$1" label="$2"
  ensure_flatpak || return 1
  flatpak info --system "$app" >/dev/null 2>&1 && { STATUS["$label"]="Installed"; ok "$label is already installed"; return 0; }
  flatpak install --system -y flathub "$app" >>"$LOG_FILE" 2>&1 &&
    { STATUS["$label"]="Installed"; ok "$label installed"; return 0; }
  error "$label installation failed"; return 1
}

install_tailscale() {
  command -v tailscale >/dev/null 2>&1 && { STATUS["Tailscale"]="Installed"; ok "Tailscale is already installed"; return; }
  info "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh 2>>"$LOG_FILE" | sh >>"$LOG_FILE" 2>&1 &&
    { STATUS["Tailscale"]="Installed"; ok "Tailscale installed"; return; }
  error "Tailscale installation failed"
}

install_sunshine() {
  command -v sunshine >/dev/null 2>&1 && { STATUS["Sunshine"]="Installed"; ok "Sunshine is already installed"; return; }
  apt_install jq jq jq || return
  local url
  url="$(curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest |
    jq -r '[.assets[]|select(.name|test("ubuntu.*24\\.04.*amd64.*\\.deb$";"i"))][0].browser_download_url //
           [.assets[]|select(.name|test("amd64.*\\.deb$";"i"))][0].browser_download_url // empty')"
  [[ -n "$url" ]] || { error "Compatible Sunshine package not found"; return; }
  install_deb Sunshine "$url" /tmp/sunshine-latest.deb sunshine || true
}

install_missing_apps() {
  echo; echo "========================================="; echo "Install Missing Applications"; echo "========================================="
  wait_apt || return
  apt-get update >>"$LOG_FILE" 2>&1 || error "APT package index update failed"

  apt_install curl curl curl || true
  apt_install wget wget wget || true
  apt_install ca-certificates update-ca-certificates "CA certificates" || true
  apt_install ffmpeg ffmpeg FFmpeg || true
  apt_install mangohud mangohud MangoHud || true
  apt_install gamemode gamemoderun GameMode || true
  apt_install nvtop nvtop nvtop || true
  apt_install btop btop btop || true
  apt_install vulkan-tools vulkaninfo "Vulkan Tools" || true
  apt_install mesa-utils glxinfo "Mesa Utilities" || true
  apt_install x11-xserver-utils xrandr "X11 Utilities" || true
  apt_install xcvt cvt "CVT utility" || true

  install_deb "Google Chrome" \
    "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
    /tmp/google-chrome.deb google-chrome || true
  install_deb Discord \
    "https://discord.com/api/download?platform=linux&format=deb" \
    /tmp/discord.deb discord || true
  install_flatpak net.davidotek.pupgui2 ProtonUp-Qt || true
  install_tailscale
  install_sunshine
}

system_update() {
  echo; echo "========================================="; echo "System Update"; echo "========================================="
  wait_apt || return
  run_logged "Updating APT package indexes" apt-get update || true
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >>"$LOG_FILE" 2>&1 &&
    ok "Installed packages updated" || error "Package update failed"
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >>"$LOG_FILE" 2>&1 &&
    ok "Unused packages removed" || warn "Autoremove reported a problem"
  apt-get autoclean >>"$LOG_FILE" 2>&1 && ok "APT cache cleaned" || warn "Autoclean reported a problem"
}

update_gaming_apps() {
  echo; echo "========================================="; echo "Gaming Applications Update"; echo "========================================="
  local candidates=(steam lutris winehq-staging wine-staging firefox google-chrome-stable discord tailscale sunshine ffmpeg mangohud gamemode nvtop btop)
  local installed=() p
  for p in "${candidates[@]}"; do dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p"); done
  if ((${#installed[@]})); then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${installed[@]}" >>"$LOG_FILE" 2>&1 &&
      ok "Gaming applications checked and updated" || warn "Some gaming applications could not be updated"
  fi
  command -v flatpak >/dev/null 2>&1 &&
    { flatpak update --system -y >>"$LOG_FILE" 2>&1 && ok "Flatpak applications checked and updated" || warn "Flatpak update reported a problem"; }
}

configure_tailscale() {
  echo; echo "========================================="; echo "Configure Tailscale"; echo "========================================="
  command -v tailscale >/dev/null 2>&1 || { error "Tailscale is not installed"; return; }
  systemctl enable --now tailscaled >>"$LOG_FILE" 2>&1 || warn "tailscaled could not be enabled automatically"
  if ! tailscale status >/dev/null 2>&1; then
    if [[ -t 0 ]]; then tailscale up 2>&1 | tee -a "$LOG_FILE" || true
    else warn "Interactive Tailscale login required"; fi
  fi
  if tailscale status >/dev/null 2>&1; then
    TAILSCALE_IP="$(tailscale ip -4 | head -n1)"
    SUNSHINE_URL="https://$TAILSCALE_IP:47990"
    STATUS["Tailscale"]="Connected"
    ok "Tailscale connected"
    printf '\nConnected\n\nIP:\n%s\n' "$TAILSCALE_IP"
  else
    STATUS["Tailscale"]="Not connected"; warn "Tailscale is not connected"
  fi
}

sunshine_service() {
  for s in sunshine.service app-dev.lizardbyte.app.Sunshine.service; do
    run_user systemctl --user list-unit-files "$s" --no-legend 2>/dev/null | grep -q "$s" && { echo "$s"; return; }
  done
}

set_conf() {
  local file="$1" key="$2" value="$3"
  grep -qE "^[[:space:]]*$key[[:space:]]*=" "$file" &&
    sed -i -E "s|^[[:space:]]*$key[[:space:]]*=.*|$key = $value|" "$file" ||
    printf '%s = %s\n' "$key" "$value" >>"$file"
}

configure_sunshine() {
  echo; echo "========================================="; echo "Configure Sunshine"; echo "========================================="
  command -v sunshine >/dev/null 2>&1 || { error "Sunshine is not installed"; return; }
  local dir="$DESKTOP_HOME/.config/sunshine" file="$dir/sunshine.conf" service
  install -d -m 700 -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$dir"
  touch "$file"; chown "$DESKTOP_USER:$DESKTOP_USER" "$file"; chmod 600 "$file"
  set_conf "$file" encoder nvenc
  set_conf "$file" upnp disabled
  if [[ "$TAILSCALE_IP" != "Not connected" ]]; then
    set_conf "$file" origin_web_ui_allowed lan
    set_conf "$file" csrf_allowed_origins "https://$TAILSCALE_IP:47990"
  fi
  chown "$DESKTOP_USER:$DESKTOP_USER" "$file"
  service="$(sunshine_service || true)"
  if [[ -n "$service" ]] && run_user systemctl --user enable --now "$service" >>"$LOG_FILE" 2>&1; then
    STATUS["Sunshine"]="Running"; ok "Sunshine service is running"
  else
    STATUS["Sunshine"]="Service not running"; warn "Sunshine user service could not be started"
  fi
  ss -ltn | grep -q ':47990 ' && ok "Sunshine Web UI port is listening" || warn "Sunshine Web UI port is not listening yet"
}

find_desktop_file() {
  local p r
  for p in "$@"; do
    r="$(find /usr/share/applications /var/lib/flatpak/exports/share/applications "$DESKTOP_HOME/.local/share/applications" \
      -maxdepth 2 -type f -iname "$p" 2>/dev/null | head -n1)"
    [[ -n "$r" ]] && { echo "$r"; return; }
  done
}

shortcut() {
  local label="$1"; shift
  local src="$(find_desktop_file "$@" || true)"
  [[ -n "$src" ]] || { warn "Shortcut source not found for $label"; return; }
  cp "$src" "$DESKTOP_HOME/Desktop/$label.desktop"
  chown "$DESKTOP_USER:$DESKTOP_USER" "$DESKTOP_HOME/Desktop/$label.desktop"
  chmod +x "$DESKTOP_HOME/Desktop/$label.desktop"
  ok "$label desktop shortcut created"
}

configure_desktop() {
  echo; echo "========================================="; echo "Configure Desktop"; echo "========================================="
  install -d -m 755 -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$DESKTOP_HOME/Desktop"
  if command -v lookandfeeltool >/dev/null 2>&1 &&
     run_user lookandfeeltool -a org.kde.breezedark.desktop >>"$LOG_FILE" 2>&1; then
    STATUS["Theme"]="Dark"; ok "KDE dark theme applied"
  else STATUS["Theme"]="Not applied"; warn "KDE dark theme could not be applied"; fi
  STATUS["Wallpaper"]="Existing wallpaper kept"

  shortcut Steam steam.desktop com.valvesoftware.Steam.desktop || true
  shortcut "Google Chrome" google-chrome.desktop 'google-chrome*.desktop' || true
  shortcut Firefox firefox.desktop org.mozilla.firefox.desktop || true
  shortcut Lutris net.lutris.Lutris.desktop lutris.desktop || true

  cat >"$DESKTOP_HOME/Desktop/Sunshine Web UI.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Sunshine Web UI
Exec=xdg-open ${SUNSHINE_URL/Unavailable/https:\/\/localhost:47990}
Icon=applications-internet
Terminal=false
EOF
  cat >"$DESKTOP_HOME/Desktop/Trash.desktop" <<'EOF'
[Desktop Entry]
Type=Link
Name=Trash
Icon=user-trash
URL=trash:/
EOF
  chown "$DESKTOP_USER:$DESKTOP_USER" "$DESKTOP_HOME/Desktop/"*.desktop
  chmod +x "$DESKTOP_HOME/Desktop/"*.desktop
  ok "Desktop shortcuts configured"
}

primary_output() {
  run_user xrandr --query 2>/dev/null | awk '/ connected primary /{print $1;exit}/ connected /&&!x{x=$1}END{if(x)print x}' | head -n1
}

current_resolution() {
  run_user xrandr --current 2>/dev/null | awk '/ connected /{for(i=1;i<=NF;i++)if($i~/^[0-9]+x[0-9]+\+/){split($i,a,"+");print a[1];exit}}'
}

current_refresh() {
  run_user xrandr --current 2>/dev/null | awk '/\*/{gsub(/[^0-9.]/,"",$2);print $2;exit}'
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
  [[ -t 0 ]] || { RESOLUTION="$(current_resolution || echo "Keep current")"; return; }
  while read -r choice; do
    case "$choice" in
      1) RESOLUTION=1024x768;; 2) RESOLUTION=1280x720;; 3) RESOLUTION=1366x768;;
      4) RESOLUTION=1600x900;; 5) RESOLUTION=1920x1080;; 6) RESOLUTION=2560x1440;;
      7) RESOLUTION=3840x2160;; 8) RESOLUTION=2560x1080;; 9) RESOLUTION=3440x1440;;
      10) RESOLUTION="$(current_resolution || echo "Keep current")";;
      *) echo "Invalid choice. Enter 1-10:"; continue;;
    esac; break
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
  [[ -t 0 ]] || { REFRESH_RATE="$(current_refresh || echo "Keep current")"; return; }
  while read -r choice; do
    case "$choice" in
      1) REFRESH_RATE=60;; 2) REFRESH_RATE=75;; 3) REFRESH_RATE=90;; 4) REFRESH_RATE=120;;
      5) REFRESH_RATE=144;; 6) REFRESH_RATE=165;; 7) REFRESH_RATE=240;;
      8) REFRESH_RATE="$(current_refresh || echo "Keep current")";;
      *) echo "Invalid choice. Enter 1-8:"; continue;;
    esac; break
  done
}

apply_display() {
  local output="$(primary_output)"
  [[ -n "$output" ]] || { error "No connected X11 output found"; return; }
  if run_user xrandr --output "$output" --mode "$RESOLUTION" --rate "$REFRESH_RATE" >>"$LOG_FILE" 2>&1; then
    ok "Display set to $RESOLUTION at $REFRESH_RATE Hz"; return
  fi
  local w="${RESOLUTION%x*}" h="${RESOLUTION#*x}" modeline name
  modeline="$(cvt "$w" "$h" "$REFRESH_RATE" 2>/dev/null | awk '/Modeline/{$1="";sub(/^ /,"");print}')"
  [[ -n "$modeline" ]] || { error "Could not create display modeline"; return; }
  name="$(awk '{gsub(/"/,"",$1);print $1}' <<<"$modeline")"
  run_user xrandr --newmode $modeline >>"$LOG_FILE" 2>&1 || true
  run_user xrandr --addmode "$output" "$name" >>"$LOG_FILE" 2>&1 || true
  run_user xrandr --output "$output" --mode "$name" >>"$LOG_FILE" 2>&1 &&
    ok "Display set to $RESOLUTION at $REFRESH_RATE Hz" || error "Display configuration failed"
}

configure_display() {
  echo; echo "========================================="; echo "Configure Display"; echo "========================================="
  choose_resolution
  choose_refresh
  [[ "$RESOLUTION" == "Keep current" ]] && RESOLUTION="$(current_resolution || echo "Keep current")"
  [[ "$REFRESH_RATE" == "Keep current" ]] && REFRESH_RATE="$(current_refresh || echo "Keep current")"
  [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ && "$REFRESH_RATE" =~ ^[0-9]+([.][0-9]+)?$ ]] && apply_display ||
    warn "Display configuration was kept unchanged"
  STATUS["Resolution"]="$RESOLUTION"
  STATUS["Refresh rate"]="$REFRESH_RATE Hz"
}

cleanup() {
  echo; echo "========================================="; echo "Cleanup"; echo "========================================="
  wait_apt || return
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >>"$LOG_FILE" 2>&1 && ok "Unused packages removed" || warn "Autoremove reported a problem"
  apt-get autoclean >>"$LOG_FILE" 2>&1 && ok "APT cache cleaned" || warn "Autoclean reported a problem"
  rm -f /tmp/google-chrome.deb /tmp/discord.deb /tmp/sunshine-latest.deb
}

value() { printf '%s' "${STATUS[$1]:-Not detected}"; }

summary() {
  command -v steam >/dev/null 2>&1 && STATUS["Steam"]="OK"
  command -v google-chrome >/dev/null 2>&1 && STATUS["Google Chrome"]="OK"
  command -v firefox >/dev/null 2>&1 && STATUS["Firefox"]="OK"
  command -v discord >/dev/null 2>&1 && STATUS["Discord"]="OK"
  command -v lutris >/dev/null 2>&1 && STATUS["Lutris"]="OK"
  command -v wine >/dev/null 2>&1 && STATUS["Wine"]="OK"

  echo; echo "========================================="; echo "Linux-Gaming-VM Summary"; echo "========================================="
  echo; echo "System"; echo "-------------------------"
  printf '%-18s %s\n' "GPU.............." "$(value GPU)"
  printf '%-18s %s\n' "Driver..........." "$(value Driver)"
  printf '%-18s %s\n' "CUDA............." "$(value CUDA)"
  printf '%-18s %s\n' "NVENC............" "$(value NVENC)"
  printf '%-18s %s\n' "OpenGL..........." "$(value OpenGL)"
  printf '%-18s %s\n' "Vulkan..........." "$(value Vulkan)"
  echo; echo "Applications"; echo "-------------------------"
  printf '%-18s %s\n' "Steam............" "$(value Steam)"
  printf '%-18s %s\n' "Chrome..........." "$(value "Google Chrome")"
  printf '%-18s %s\n' "Firefox.........." "$(value Firefox)"
  printf '%-18s %s\n' "Discord.........." "$(value Discord)"
  printf '%-18s %s\n' "Lutris..........." "$(value Lutris)"
  printf '%-18s %s\n' "Wine............." "$(value Wine)"
  printf '%-18s %s\n' "Sunshine........." "$(value Sunshine)"
  printf '%-18s %s\n' "Tailscale........" "$(value Tailscale)"
  echo; echo "Desktop"; echo "-------------------------"
  printf '%-18s %s\n' "Theme............" "$(value Theme)"
  printf '%-18s %s\n' "Wallpaper........" "$(value Wallpaper)"
  printf '%-18s %s\n' "Resolution......." "$(value Resolution)"
  printf '%-18s %s\n' "Refresh Rate....." "$(value "Refresh rate")"
  echo; echo "Network"; echo "-------------------------"
  printf '%-18s %s\n' "Tailscale IP....." "$TAILSCALE_IP"
  printf '%-18s %s\n' "Sunshine Web....." "$SUNSHINE_URL"
  echo
  echo "Finished with $ERRORS Error(s) and $WARNINGS Warning(s)"
  ((ERRORS+WARNINGS>0)) && echo "A diagnostic log was generated for troubleshooting."
  echo "========================================="
  write_log INFO "Finished with $ERRORS error(s) and $WARNINGS warning(s)"
}

main() {
  require_root
  init_log
  banner
  detect_environment
  verify_system
  install_missing_apps
  system_update
  update_gaming_apps
  configure_tailscale
  configure_sunshine
  configure_desktop
  configure_display
  cleanup
  summary
}

main "$@"
