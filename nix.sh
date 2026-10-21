#!/usr/bin/env bash
# ============================================
# SKRYPT KONFIGURACJI WIZUALNEJ GNOME (NixOS)
# ============================================

set -Eeuo pipefail

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
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}✘ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
        else
            echo -e "${ERR}✘ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
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

TOTAL_STEPS=7

CURRENT_USER=$(whoami)
USER_PICTURES_DIR="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")"
wallpaper_PATH="$USER_PICTURES_DIR/wallpaper.jpg"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$EUID" -eq 0 ]]; then
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}✘ Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo.${NC}" >&3
    else
        echo -e "${ERR}✘ Do not run this script as root. Run as a normal user with sudo.${NC}" >&3
    fi
    exit 1
fi

# ==========================================
# 1. UPRAWNIENIA TYMCZASOWE (SUDO / POLKIT)
# ==========================================
RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1; then
    USE_RUN0=1
elif command -v run0 >/dev/null 2>&1 && sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

printf '\033[?7h' >&3
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
    if sudo visudo -cf "$SUDOERS_TMP" >/dev/null; then
        sudo mkdir -p /etc/sudoers.d
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
    else
        rm -f "$SUDOERS_TMP"
        log_err "Nieprawidłowa składnia reguły sudoers - przerywam." "Invalid sudoers rule syntax - aborting."
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
    SUDO_READY=1
fi

printf '\033[?7l' >&3

show_progress 0 $TOTAL_STEPS "$MSG_PREP"

# ==========================================
# 2. KONFIGURACJA SYSTEMOWA (NIXOS)
# ==========================================
NIXOS_DIR="/etc/nixos"
NIXOS_CONF="$NIXOS_DIR/configuration.nix"
GNOME_MODULE="$NIXOS_DIR/gnome-visual.nix"

if [[ ! -f "$NIXOS_CONF" ]]; then
    log_err "Nie znaleziono $NIXOS_CONF." "$NIXOS_CONF not found."
    exit 1
fi

if [[ -f "$SCRIPT_DIR/piwo.png" ]]; then
    cp -af "$SCRIPT_DIR/piwo.png" "$HOME/.face" 2>/dev/null || true
    chmod 644 "$HOME/.face" 2>/dev/null || true

    AVATAR_DEST="/var/lib/AccountsService/icons/$CURRENT_USER"
    ACCOUNTS_FILE="/var/lib/AccountsService/users/$CURRENT_USER"

    sudo mkdir -p /var/lib/AccountsService/icons/ /var/lib/AccountsService/users/ || true
    sudo cp -f "$SCRIPT_DIR/piwo.png" "$AVATAR_DEST" || true
    sudo chmod 644 "$AVATAR_DEST" || true

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        echo -e "[User]\nIcon=$AVATAR_DEST" | sudo tee "$ACCOUNTS_FILE" > /dev/null
    elif sudo grep -q "^Icon=" "$ACCOUNTS_FILE"; then
        sudo sed -i "s|^Icon=.*|Icon=$AVATAR_DEST|" "$ACCOUNTS_FILE" || true
    elif sudo grep -q "^\[User\]" "$ACCOUNTS_FILE"; then
        sudo sed -i "/^\[User\]/a Icon=$AVATAR_DEST" "$ACCOUNTS_FILE" || true
    else
        echo "Icon=$AVATAR_DEST" | sudo tee -a "$ACCOUNTS_FILE" > /dev/null
    fi

    sudo systemctl restart accounts-daemon 2>/dev/null || true
fi

LOGIN_WALLPAPER_NIX="# brak tapety logowania"
if [[ -f "$SCRIPT_DIR/login-wallpaper.png" ]]; then
    sudo install -m 644 -o root -g root "$SCRIPT_DIR/login-wallpaper.png" "$NIXOS_DIR/login-wallpaper.png"
    LOGIN_WALLPAPER_NIX='programs.dconf.profiles.gdm.databases = [
    {
      settings."org/gnome/desktop/background" = {
        picture-uri = "file://${./login-wallpaper.png}";
        picture-uri-dark = "file://${./login-wallpaper.png}";
        picture-options = "zoom";
      };
    }
  ];'
fi

GNOME_MODULE_TMP="$(mktemp)"
cat > "$GNOME_MODULE_TMP" <<'NIX_EOF'
{ config, pkgs, lib, ... }:

let
  packageNames = [
    "gnome-tweaks"
    "gnome-shell-extensions"
    "gnome-extension-manager"
    "dconf"
  ];

  extensionUuids = [
    "ding@rastersoft.com"
    "tiling-assistant@ubuntu.com"
    "compiz-alike-magic-lamp-effect@hermes83.github.com"
    "compiz-windows-effect@hermes83.github.com"
    "blur-my-shell@aunetx"
    "weatherpanel@attentivecoder"
    "clipboard-history@alexsaveau.dev"
    "system-monitor-panel@naimur"
    "dash-to-dock@micxgx.gmail.com"
  ];

  try = v: let r = builtins.tryEval v; in if r.success then r.value else null;

  lookup = n:
    let
      top = try (pkgs.${n} or null);
      sub = try (pkgs.gnome.${n} or null);
    in
      if lib.isDerivation top then top
      else if lib.isDerivation sub then sub
      else null;
  usable = p: p != null && !(p.meta.broken or false);

  allExtensions = map (n: try (pkgs.gnomeExtensions.${n} or null))
    (builtins.attrNames pkgs.gnomeExtensions);
  uuidOf = e: if e == null then null else try (e.extensionUuid or null);
  foundExtensions = lib.filter
    (e: lib.isDerivation e && usable e && lib.elem (uuidOf e) extensionUuids)
    allExtensions;
  missingUuids = lib.filter
    (u: !(lib.elem u (map uuidOf foundExtensions)))
    extensionUuids;
in
{
  environment.systemPackages =
    lib.filter usable (map lookup packageNames) ++ foundExtensions;

  programs.dconf.enable = lib.mkDefault true;

  warnings = map
    (u: "gnome-visual: brak rozszerzenia ${u} w nixpkgs - pomijam / not found in nixpkgs - skipping")
    missingUuids;

  @LOGIN_WALLPAPER@
}
NIX_EOF

NIX_CONTENT="$(cat "$GNOME_MODULE_TMP")"
printf '%s\n' "${NIX_CONTENT//@LOGIN_WALLPAPER@/$LOGIN_WALLPAPER_NIX}" > "$GNOME_MODULE_TMP"

sudo install -m 644 -o root -g root "$GNOME_MODULE_TMP" "$GNOME_MODULE"
rm -f "$GNOME_MODULE_TMP"

sudo cp -f "$NIXOS_CONF" "$NIXOS_CONF.bak"
if ! sudo grep -q "gnome-visual.nix" "$NIXOS_CONF"; then
    if sudo grep -q "\./hardware-configuration\.nix" "$NIXOS_CONF"; then
        sudo sed -i 's|\./hardware-configuration\.nix|& ./gnome-visual.nix|' "$NIXOS_CONF"
    else
        log_err "Nie można dodać ./gnome-visual.nix do imports w $NIXOS_CONF - dodaj ręcznie." \
                "Cannot add ./gnome-visual.nix to imports in $NIXOS_CONF - add it manually."
        exit 1
    fi
fi

show_progress 1 $TOTAL_STEPS "$MSG_INSTALL"

if ! sudo nixos-rebuild switch; then
    sudo cp -f "$NIXOS_CONF.bak" "$NIXOS_CONF"
    log_err "nixos-rebuild nie powiódł się - przywrócono configuration.nix." "nixos-rebuild failed - configuration.nix restored."
    exit 1
fi

show_progress 2 $TOTAL_STEPS "$MSG_INSTALL"

# ==========================================
# 3. KOPIOWANIE PLIKÓW KONFIGURACYJNYCH
# ==========================================
safe_copy_dir() {
    local src="$1" dst="$2"
    if [[ -d "$src" ]] && [[ "$(realpath "$src" 2>/dev/null)" != "$(realpath "$dst" 2>/dev/null)" ]]; then
        mkdir -p "$dst" 2>/dev/null || return 0
        cp -af "$src/." "$dst/" 2>/dev/null || true
    fi
    return 0
}

safe_copy_dir "$SCRIPT_DIR/.config" ~/.config
safe_copy_dir "$SCRIPT_DIR/.local" ~/.local
safe_copy_dir "$SCRIPT_DIR/.icons" ~/.icons
safe_copy_dir "$SCRIPT_DIR/.themes" ~/.themes

if [[ -f "$SCRIPT_DIR/wallpaper.jpg" ]]; then
    mkdir -p "$(dirname "$wallpaper_PATH")" 2>/dev/null
    cp -af "$SCRIPT_DIR/wallpaper.jpg" "$wallpaper_PATH" 2>/dev/null || true
fi
chmod 644 "$wallpaper_PATH" 2>/dev/null || true

show_progress 3 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 4. USTAWIENIA GNOME (GSETTINGS / DCONF)
# ==========================================
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    RUNTIME_DIR="/run/user/$(id -u)"
    if [[ -S "$RUNTIME_DIR/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"
    fi
fi

if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.background picture-uri "file://$wallpaper_PATH" 2>/dev/null \
        && gsettings set org.gnome.desktop.background picture-uri-dark "file://$wallpaper_PATH" 2>/dev/null \
        && gsettings set org.gnome.desktop.background picture-options "zoom" 2>/dev/null || true

    gsettings set org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop']" 2>/dev/null || true
fi

show_progress 4 $TOTAL_STEPS "$MSG_OPTIMIZE"

if command -v dconf >/dev/null 2>&1; then
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
disabled-extensions=@as []
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

show_progress 5 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 5. ZAKOŃCZENIE I SPRZĄTANIE
# ==========================================
rm -rf "$HOME/.cache/thumbnails" 2>/dev/null || true
rm -rf "$HOME/.cache/icon-cache.kcache" 2>/dev/null || true
if command -v gtk-update-icon-cache >/dev/null 2>&1 && [[ -d "$HOME/.icons" ]]; then
    for theme_dir in "$HOME/.icons/"*/; do
        [[ -f "${theme_dir}index.theme" ]] && gtk-update-icon-cache -f -t "$theme_dir" >/dev/null 2>&1 || true
    done
fi

show_progress 6 $TOTAL_STEPS "$MSG_OPTIMIZE"
show_progress 7 $TOTAL_STEPS "$MSG_FINALIZE"
printf '\n\n' >&3

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}✔ KONFIGURACJA WIZUALNA ZAKOŃCZONA!${NC}" >&3
else
    echo -e "${SUCCESS}✔ VISUAL CONFIGURATION COMPLETED!${NC}" >&3
fi

DO_REBOOT=1
exit 0
