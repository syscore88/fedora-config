#!/bin/bash
# ====================================
# SKRYPT KONFIGURACJI WIZUALNEJ GNOME
# ====================================

set -Eeuo pipefail

FAILED_PACKAGES=()
FAILED_EXTENSIONS=()
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/sbin:/sbin:$PATH"

detect_system_lang() {
    local sys_lang="${LANG:-}"
    [[ -z "$sys_lang" ]] && sys_lang="${LC_ALL:-${LC_MESSAGES:-}}"
    if [[ "$sys_lang" == pl_PL* || "$sys_lang" == pl* ]]; then
        echo "pl"
    else
        echo "en"
    fi
}
SCRIPT_LANG="$(detect_system_lang)"

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[0;33m'
ERR='\033[0;31m'
NC='\033[0m'

TMP_LOG="$(mktemp /tmp/install-log.XXXXXX)"
LOG_FILE="$HOME/install_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

cleanup_on_exit() {
    local exit_code=$?
    declare -F restore_packagekit >/dev/null && restore_packagekit || true
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ] || [ "${#FAILED_EXTENSIONS[@]}" -gt 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}✘ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${ERR}✘ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
            fi
        else
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${WARN}⚠ Niektóre pakiety nie zostały zainstalowane. Log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${WARN}⚠ Some packages failed to install. Log saved to: $LOG_FILE${NC}" >&3
            fi
        fi
    fi
    rm -f "$TMP_LOG"
    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        sudo sh -c 'rm -f "$1" "$2"; systemctl try-restart polkit 2>/dev/null; [ "$3" = 1 ] && systemctl reboot' _ \
            "${RUN0_NOPASSWD_FILE:-/etc/polkit-1/rules.d/51-run0-nopasswd.rules}" \
            "/etc/sudoers.d/99-temp-installer" \
            "$do_reboot"
    fi
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() {
    echo -e "$1"
    echo -e "$1" >&3
}
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}✔ $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}✘ ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}⚠ WARN: $m${NC}"; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

# ==========================================================
# PACKAGEKIT + BLOKADA MENEDŻERA PAKIETÓW
# ==========================================================
PACKAGEKIT_MASKED=0
PACKAGEKIT_UNITS=(packagekit.service packagekit-offline-update.service)

disable_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] && return 0
    sudo systemctl stop "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    if command -v killall >/dev/null 2>&1; then
        sudo killall -q packagekitd 2>/dev/null || true
    else
        sudo pkill -x packagekitd 2>/dev/null || true
    fi
    sudo systemctl mask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    PACKAGEKIT_MASKED=1
}

restore_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] || return 0
    sudo systemctl unmask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    PACKAGEKIT_MASKED=0
}

_pkg_lock_busy() {
    local f
    for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock \
             /run/zypp.pid /var/run/zypp.pid /var/lib/pacman/db.lck \
             /var/cache/dnf/metadata_lock.pid /var/lib/rpm/.rpm.lock; do
        [[ -e "$f" ]] || continue
        sudo fuser "$f" >/dev/null 2>&1 && return 0
    done
    pgrep -x 'apt|apt-get|dpkg|zypper|pacman|dnf|dnf5|packagekitd' >/dev/null 2>&1 && return 0
    return 1
}

wait_for_pkg_lock() {
    local timeout="${1:-300}" waited=0
    disable_packagekit
    while _pkg_lock_busy; do
        if (( waited >= timeout )); then
            log_warn "Blokada menedżera pakietów trwa ponad ${timeout}s - kontynuuję mimo to." \
                     "Package manager lock held for over ${timeout}s - continuing anyway."
            break
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
}

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(stty size </dev/tty 2>/dev/null || true)
    cols="${cols##* }"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols=80

    local bar_width=50
    local reserved=14
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 1))}…"
    fi

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ $filled -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ $empty -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
}

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    MSG_PREP="Przygotowywanie..."
    MSG_INSTALL="Instalacja..."
    MSG_OPTIMIZE="Optymalizacja..."
    MSG_FINALIZE="Finalizowanie..."
else
    MSG_PREP="Preparing..."
    MSG_INSTALL="Installation..."
    MSG_OPTIMIZE="Optimization..."
    MSG_FINALIZE="Finalizing..."
fi

TOTAL_STEPS=12

CURRENT_USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
USER_PICTURES="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")"
wallpaper_PATH="$USER_PICTURES/wallpaper.jpg"

if [[ "$EUID" -eq 0 ]]; then
    echo -e "${ERR}✘ Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo.${NC}" >&3
    exit 1
fi

RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1; then
    USE_RUN0=1
elif command -v run0 >/dev/null 2>&1 && sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

SUDO_READY=0
if [[ "$USE_RUN0" -eq 1 ]]; then
    sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null <<POLKIT_RULE_EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
POLKIT_RULE_EOF
    sudo systemctl try-restart polkit 2>/dev/null || true
    SUDO_READY=1
else
    sudo -v

    (
        set +e
        trap - ERR
        while true; do
            sudo -n true
            sleep 60
            kill -0 "$$" 2>/dev/null || exit
        done
    ) &
    SUDO_KEEPALIVE_PID=$!

    SUDOERS_TMP="$(mktemp)"
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null; then
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
    else
        rm -f "$SUDOERS_TMP"
        log_err "Nieprawidłowa składnia reguły sudoers." "Invalid sudoers rule syntax."
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
    SUDO_READY=1
fi

# ==========================================================
# 1. WSTĘPNE SPRAWDZENIA I UPRAWNIENIA
# ==========================================================
show_progress 0 $TOTAL_STEPS "$MSG_PREP"

printf '\033[?7h' >&3

printf '\033[?7l' >&3

show_progress 1 $TOTAL_STEPS "$MSG_PREP"

# ==========================================================
# 2. WYKRYWANIE DYSTRYBUCJI I INSTALACJA PAKIETÓW
# ==========================================================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="${ID:-}"
        OS_LIKE="${ID_LIKE:-${ID:-}}"
    else
        OS="unknown"
        OS_LIKE=""
    fi
}

install_gnome_packages() {
    wait_for_pkg_lock
    if [[ "$OS_LIKE" == *"ubuntu"* || "$OS_LIKE" == *"debian"* ]]; then
        sudo apt-get update -yq || true
        for pkg in gnome-tweaks gnome-shell-extension-prefs gnome-shell-extensions dconf-cli; do
            sudo apt-get install -yq "$pkg" || FAILED_PACKAGES+=("$pkg")
        done
    elif [[ "$OS_LIKE" == *"fedora"* ]]; then
        for pkg in gnome-tweaks gnome-extensions-app dconf; do
            sudo dnf install -yq "$pkg" || FAILED_PACKAGES+=("$pkg")
        done
    elif [[ "$OS_LIKE" == *"arch"* ]]; then
        for pkg in gnome-tweaks gnome-shell-extensions dconf; do
            sudo pacman -S --noconfirm --needed "$pkg" || FAILED_PACKAGES+=("$pkg")
        done
    elif [[ "$OS_LIKE" == *"suse"* ]]; then
        for pkg in gnome-tweaks gnome-shell-extensions-common dconf; do
            sudo zypper -q -n install -y "$pkg" || FAILED_PACKAGES+=("$pkg")
        done
    else
        log_warn "Nierozpoznana dystrybucja ($OS) - pomijam instalację pakietów GNOME. Zainstaluj ręcznie: gnome-tweaks, gnome-shell-extensions, dconf-cli/dconf." \
                 "Unrecognized distribution ($OS) - skipping GNOME package installation. Install manually: gnome-tweaks, gnome-shell-extensions, dconf-cli/dconf."
    fi

    if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
        log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}. Sprawdź log: $LOG_FILE" \
                 "Failed to install: ${FAILED_PACKAGES[*]}. Check the log: $LOG_FILE"
    fi
}

detect_os
disable_packagekit
show_progress 2 $TOTAL_STEPS "$MSG_INSTALL"

install_gnome_packages
show_progress 3 $TOTAL_STEPS "$MSG_INSTALL"

# ==========================================================
# 3. KONFIGURACJA WIZUALNA GNOME
# ==========================================================
show_progress 4 $TOTAL_STEPS "$MSG_OPTIMIZE"

restore_packagekit

if [[ -d "$SCRIPT_DIR/.config" ]]; then cp -af "$SCRIPT_DIR/.config/." ~/.config/ || true; fi
if [[ -d "$SCRIPT_DIR/.local" ]]; then cp -af "$SCRIPT_DIR/.local/." ~/.local/ || true; fi

if [[ -d "$SCRIPT_DIR/.icons" ]]; then
    mkdir -p ~/.icons
    cp -af "$SCRIPT_DIR/.icons/." ~/.icons/ || true
fi

if [[ -f "$SCRIPT_DIR/wallpaper.jpg" ]]; then
    mkdir -p "$(dirname "$wallpaper_PATH")"
    cp -af "$SCRIPT_DIR/wallpaper.jpg" "$wallpaper_PATH" || true
fi

show_progress 5 $TOTAL_STEPS "$MSG_OPTIMIZE"

if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.background picture-uri "file://$wallpaper_PATH" 2>/dev/null \
        && gsettings set org.gnome.desktop.background picture-uri-dark "file://$wallpaper_PATH" 2>/dev/null \
        && gsettings set org.gnome.desktop.background picture-options "zoom" 2>/dev/null || true

    gsettings set org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop']" 2>/dev/null || true
fi

show_progress 6 $TOTAL_STEPS "$MSG_OPTIMIZE"

if command -v dconf &>/dev/null; then
    mkdir -p "$HOME/.config/dconf"

    dconf load / <<'DCONF_EOF' || true
[org/gnome/Ptyxis/Profiles/979e3c3bcf05a3fa49ec466f6a5d0ca7]
bold-is-bright=true
palette='xterm'

[org/gnome/TextEditor]
restore-session=false

[org/gnome/deja-dup]
backend='google'
periodic-timestamp='2026-07-19T19:39:27.503131+02'
prompt-check='2026-07-19T19:41:27.902242+02'

[org/gnome/desktop/calendar]
show-weekdate=true
week-start-day='monday'

[org/gnome/desktop/interface]
accent-color='purple'
clock-show-seconds=true
clock-show-weekday=true
color-scheme='prefer-dark'
cursor-theme='McMojave-Cursors'
gtk-theme='Mojave-Dark'
icon-theme='kora'
toolkit-accessibility=false

[org/gnome/desktop/wm/preferences]
button-layout='appmenu:minimize,maximize,close'

[org/gnome/shell]
disabled-extensions=['ubuntu-dock@ubuntu.com', 'ubuntu-appindicators@ubuntu.com']
enabled-extensions=['ding@rastersoft.com', 'tiling-assistant@ubuntu.com', 'compiz-alike-magic-lamp-effect@hermes83.github.com', 'blur-my-shell@aunetx', 'weatherpanel@attentivecoder', 'compiz-windows-effect@hermes83.github.com', 'clipboard-history@alexsaveau.dev', 'system-monitor-panel@naimur', 'dash-to-dock@micxgx.gmail.com']

[org/gnome/shell/extensions/appindicator]
icon-brightness=0.0
icon-contrast=0.0
icon-opacity=240
icon-saturation=0.0
icon-size=0

[org/gnome/shell/extensions/blur-my-shell]
pipelines={'pipeline_default': {'name': <'Default'>, 'effects': <[<{'type': <'native_static_gaussian_blur'>, 'id': <'effect_000000000000'>, 'params': <{'radius': <30>, 'brightness': <0.78000000000000003>, 'unscaled_radius': <45>}>}>, <{'type': <'corner'>, 'id': <'effect_10639405078369'>, 'params': <{'radius': <130>, 'corners_top': <true>, 'corners_bottom': <true>}>}>]>}}
rounded-blur-found=false
settings-version=2

[org/gnome/shell/extensions/blur-my-shell/appfolder]
brightness=0.59999999999999998
sigma=22

[org/gnome/shell/extensions/blur-my-shell/applications]
blur=true
brightness=0.84999999999999998
pipeline='pipeline_default'

[org/gnome/shell/extensions/blur-my-shell/coverflow-alt-tab]
pipeline='pipeline_default'

[org/gnome/shell/extensions/blur-my-shell/dash-to-dock]
blur=false
brightness=0.59999999999999998
override-background=true
pipeline='pipeline_default'
sigma=30
static-blur=false
style-dash-to-dock=0

[org/gnome/shell/extensions/blur-my-shell/dash-to-panel]
blur-original-panel=false

[org/gnome/shell/extensions/blur-my-shell/hidetopbar]
compatibility=false

[org/gnome/shell/extensions/blur-my-shell/lockscreen]
pipeline='pipeline_default'

[org/gnome/shell/extensions/blur-my-shell/overview]
pipeline='pipeline_default'
style-components=3

[org/gnome/shell/extensions/blur-my-shell/panel]
brightness=0.75
corner-radius=0
force-light-text=true
override-background=true
override-background-dynamically=true
pipeline='pipeline_default'
sigma=10
static-blur=false
style-panel=0

[org/gnome/shell/extensions/blur-my-shell/screenshot]
pipeline='pipeline_default'

[org/gnome/shell/extensions/blur-my-shell/window-list]
brightness=0.59999999999999998
sigma=30

[org/gnome/shell/extensions/com/github/hermes83/compiz-windows-effect]
last-version=31
preset='R'

[org/gnome/shell/extensions/dash-to-dock]
always-center-icons=true
apply-custom-theme=false
background-opacity=0.40000000000000002
custom-theme-shrink=true
dash-max-icon-size=40
dock-position='BOTTOM'
extend-height=false
height-fraction=0.78000000000000003
hide-tooltip=true
multi-monitor=true
preferred-monitor=-2
preferred-monitor-by-connector='Virtual-1'
preview-size-scale=0.20000000000000001
running-indicator-style='DOT'
show-apps-always-in-the-edge=false
show-apps-at-top=true
show-favorites=true
show-mounts=false
show-mounts-only-mounted=false
show-running=true
show-trash=false
transparency-mode='FIXED'

[org/gnome/shell/extensions/ding]
check-x11wayland=true
show-home=false

[org/gnome/shell/extensions/system-monitor-panel]
network-unit='bytes'
refresh-interval=15
show-cpu=false
show-disk=false
show-external-disks=true
show-gpu=false
show-gpu-card=true
show-icons=false
show-memory=false
show-network=true
show-temperature=false

[org/gnome/shell/extensions/system-monitor]
memory-calculation-method='all'
position='right'

[org/gnome/shell/extensions/tiling-assistant]
focus-hint-color='rgb(203,67,20)'
last-version-installed=54
overridden-settings={'org.gnome.mutter.edge-tiling': <@mb nothing>, 'org.gnome.mutter.keybindings.toggle-tiled-left': <@mb nothing>, 'org.gnome.mutter.keybindings.toggle-tiled-right': <@mb nothing>}
tiling-popup-all-workspace=true

[org/gnome/shell/extensions/weatherornot]
position='right'

[org/gnome/shell/extensions/weatherpanel]
actual-city=0
city='[{"label":"Warszawa","region":"województwo mazowieckie","postcode":"97-500","country":"Polska","lat":51.06713,"lon":19.44477}]'
position-in-panel='left'

[org/gnome/shell/world-clocks]
locations=@av []

[org/gnome/software]
check-timestamp=int64 1786635579
first-run=false

[org/gnome/system/location]
enabled=true

[org/gnome/terminal/legacy]
theme-variant='dark'
default-show-menubar=false

[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]
background-color='rgb(0,0,0)'
cursor-colors-set=true
cursor-foreground-color='rgb(12,18,234)'
foreground-color='rgb(20,219,138)'
use-theme-colors=false
visible-name='user'

[org/gnome/tweaks]
show-extensions-notice=false

[org/gtk/gtk4/settings/file-chooser]
show-hidden=true
sort-directories-first=true
DCONF_EOF
fi

show_progress 7 $TOTAL_STEPS "$MSG_OPTIMIZE"

if command -v pipx &>/dev/null; then
    pipx install gnome-extensions-cli --force || true

    GEXT_CMD="$HOME/.local/bin/gext"
    if command -v gext &>/dev/null; then
        GEXT_CMD="gext"
    fi

    if [[ -x "$GEXT_CMD" ]] || command -v gext &>/dev/null; then
        for ext in \
            ding@rastersoft.com \
            tiling-assistant@ubuntu.com \
            compiz-alike-magic-lamp-effect@hermes83.github.com \
            compiz-windows-effect@hermes83.github.com \
            blur-my-shell@aunetx \
            weatherpanel@attentivecoder \
            clipboard-history@alexsaveau.dev \
            system-monitor-panel@naimur \
            dash-to-dock@micxgx.gmail.com; do
            "$GEXT_CMD" install "$ext" || FAILED_EXTENSIONS+=("$ext")
        done
        if [[ ${#FAILED_EXTENSIONS[@]} -gt 0 ]]; then
            log_warn "Nie udało się zainstalować niektórych rozszerzeń: ${FAILED_EXTENSIONS[*]}. Sprawdź log: $LOG_FILE" \
                     "Failed to install some extensions: ${FAILED_EXTENSIONS[*]}. Check the log: $LOG_FILE"
        fi
    fi
fi

show_progress 8 $TOTAL_STEPS "$MSG_OPTIMIZE"

if [[ -f "$SCRIPT_DIR/piwo.png" ]]; then
    AVATAR_DEST="/var/lib/AccountsService/icons/$CURRENT_USER"
    sudo mkdir -p "$(dirname "$AVATAR_DEST")" || true
    sudo cp -af "$SCRIPT_DIR/piwo.png" "$AVATAR_DEST" || true
    sudo chmod 644 "$AVATAR_DEST" || true

    ACCOUNTS_FILE="/var/lib/AccountsService/users/$CURRENT_USER"
    if [[ -f "$ACCOUNTS_FILE" ]]; then
        if sudo grep -q "^Icon=" "$ACCOUNTS_FILE"; then
            sudo sed -i "s|^Icon=.*|Icon=$AVATAR_DEST|" "$ACCOUNTS_FILE" || true
        elif sudo grep -q "^\[User\]" "$ACCOUNTS_FILE"; then
            sudo sed -i "/^\[User\]/a Icon=$AVATAR_DEST" "$ACCOUNTS_FILE" || true
        else
            echo "Icon=$AVATAR_DEST" | sudo tee -a "$ACCOUNTS_FILE" > /dev/null
        fi
    else
        echo -e "[User]\nIcon=$AVATAR_DEST" | sudo tee "$ACCOUNTS_FILE" > /dev/null
    fi
fi

show_progress 9 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================================
# 3b. TAPETA EKRANU LOGOWANIA (GDM)
# ==========================================================
show_progress 10 $TOTAL_STEPS "$MSG_OPTIMIZE"

if [[ -f "$SCRIPT_DIR/login-wallpaper.png" ]]; then
    LOGIN_BG_DIR="/usr/share/backgrounds/custom"
    LOGIN_BG_DEST="$LOGIN_BG_DIR/login-wallpaper.png"

    sudo mkdir -p "$LOGIN_BG_DIR" || true
    sudo cp -af "$SCRIPT_DIR/login-wallpaper.png" "$LOGIN_BG_DEST" || true
    sudo chmod 644 "$LOGIN_BG_DEST" || true

    sudo mkdir -p /etc/dconf/profile || true
    if [[ ! -f /etc/dconf/profile/gdm ]] || ! grep -q "system-db:gdm" /etc/dconf/profile/gdm 2>/dev/null; then
        printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' \
            | sudo tee /etc/dconf/profile/gdm > /dev/null || true
    fi

    sudo mkdir -p /etc/dconf/db/gdm.d || true
    {
        echo "[org/gnome/desktop/background]"
        echo "picture-uri='file://$LOGIN_BG_DEST'"
        echo "picture-uri-dark='file://$LOGIN_BG_DEST'"
        echo "picture-options='zoom'"
    } | sudo tee /etc/dconf/db/gdm.d/01-login-wallpaper > /dev/null || true

    if command -v dconf &>/dev/null; then
        sudo dconf update || true
    fi
fi

# ==========================================================
# 4. ZAKOŃCZENIE I SPRZĄTANIE
# ==========================================================

show_progress 11 $TOTAL_STEPS "$MSG_FINALIZE"
printf '\n\n' >&3

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}✔ KONFIGURACJA WIZUALNA ZAKOŃCZONA!${NC}" >&3
else
    echo -e "${SUCCESS}✔ VISUAL CONFIGURATION COMPLETED!${NC}" >&3
fi

DO_REBOOT=1
exit 0
