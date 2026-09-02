#!/bin/bash
set -uo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

detect_lang() {
    local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    if [ -z "$l" ] && command -v locale &> /dev/null; then
        l=$(locale 2>/dev/null | grep -m1 '^LANG=' | cut -d= -f2)
    fi
    case "$l" in
        pl_PL*|pl*) echo "pl" ;;
        *) echo "en" ;;
    esac 
}
SCRIPT_LANG=$(detect_lang)

if [ "$SCRIPT_LANG" = "pl" ]; then
    MSG_TITLE="       KOMPLEKSOWY SKRYPT AKTUALIZACJI I CZYSZCZENIA  "
    MSG_ASK_PASS="Proszę podać hasło administratora (sudo):"
    MSG_PHASE_UPDATE="[1/4] Aktualizacja systemu i aplikacji..."
    MSG_PHASE_CLEAN_SYS="[2/4] Czyszczenie systemowe (sudo)..."
    MSG_PHASE_CLEAN_USER="[3/4] Czyszczenie użytkownika..."
    MSG_PHASE_RESTART="[4/4] Sprawdzanie konieczności restartu..."
    MSG_DONE="AKTUALIZACJA I CZYSZCZENIE ZAKOŃCZONE!"
    MSG_RESTART_WARN="UWAGA: Zalecany jest restart komputera"
    MSG_NO_RESTART="Restart systemu nie jest aktualnie wymagany."
    MSG_PRESS_ENTER="Naciśnij Enter, aby zamknąć okno..."
else
    MSG_TITLE="         COMPREHENSIVE UPDATE AND CLEANUP SCRIPT       "
    MSG_ASK_PASS="Please enter the administrator (sudo) password:"
    MSG_PHASE_UPDATE="[1/4] Updating system and applications..."
    MSG_PHASE_CLEAN_SYS="[2/4] System cleanup (sudo)..."
    MSG_PHASE_CLEAN_USER="[3/4] User cleanup..."
    MSG_PHASE_RESTART="[4/4] Checking if a restart is needed..."
    MSG_DONE="UPDATE AND CLEANUP COMPLETE!"
    MSG_RESTART_WARN="WARNING: A system restart is recommended"
    MSG_NO_RESTART="A system restart is not currently required."
    MSG_PRESS_ENTER="Press Enter to close this window..."
fi

TMP_LOG="$(mktemp /tmp/update-log.XXXXXX)"
LOG_FILE="$HOME/update_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

cleanup_on_exit() {
    local exit_code=$?
    printf '\033[?25h' >&3
    echo "" >&3
    if [ "$exit_code" -ne 0 ]; then
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$SCRIPT_LANG" = "pl" ]; then
            echo -e "${RED}✘ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
        else
            echo -e "${RED}✘ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
        fi
    fi
    rm -f "$TMP_LOG"
    kill "${SUDO_KEEP_ALIVE_PID:-}" 2>/dev/null
}
trap cleanup_on_exit EXIT

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    local bar_width=50
    local reserved=12
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

echo -e "${BLUE}======================================================${NC}" >&3
echo -e "${BLUE}${MSG_TITLE}${NC}" >&3
echo -e "${BLUE}======================================================${NC}" >&3
echo -e "${YELLOW}${MSG_ASK_PASS}${NC}" >&3
sudo -v >&3

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEP_ALIVE_PID=$!

REBOOT_NEEDED=false
FWUPD_RESTART_NEEDED=false
TOTAL_STEPS=21
STEP=0
show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

# ---------------------------------------------------------------
# PHASE: UPDATE
# ---------------------------------------------------------------
sudo apt-get update 2>&1 | grep -v "nie obsługuje architektury\|Pomijanie pozyskania skonfigurowanego pliku\|does not support architecture\|Skipping acquire of configured file"
sudo apt-get dist-upgrade -y
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v flatpak &> /dev/null; then
    flatpak update -y
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v gext &> /dev/null; then
    gext update
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v cinnamon-spice-updater &> /dev/null; then
    cinnamon-spice-updater --update-all
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

if command -v fwupdmgr &> /dev/null; then
    sudo fwupdmgr refresh --force
    FWUPD_OUT=$(sudo fwupdmgr update -y 2>&1)
    echo "$FWUPD_OUT"
    if echo "$FWUPD_OUT" | grep -qiE "restart|reboot"; then
        FWUPD_RESTART_NEEDED=true
    fi
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: SYSTEM CLEANUP (SUDO)
# ---------------------------------------------------------------
sudo apt-get autoremove --purge -y
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v deborphan &> /dev/null; then
    sudo apt-get purge $(deborphan) -y 2>/dev/null
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo apt-key net-update 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo apt-get autoclean
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo find /etc/apt/sources.list.d/ -type f -name "*.save" -delete
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v flatpak &> /dev/null; then
    sudo flatpak uninstall --unused --system -y
    sudo flatpak uninstall --unused --delete-data -y 2>/dev/null
    sudo flatpak repair --system

    USED_REMOTES=$(flatpak list --columns=origin 2>/dev/null | sort -u)
    ALL_REMOTES=$(flatpak remotes --columns=name 2>/dev/null)
    while IFS= read -r remote; do
        if [ -n "$remote" ] && ! echo "$USED_REMOTES" | grep -qx "$remote"; then
            sudo flatpak remote-delete --force "$remote" 2>/dev/null
        fi
    done <<< "$ALL_REMOTES"

    sudo rm -rf /var/tmp/flatpak-cache-* 2>/dev/null
    sudo find /var/lib/flatpak -name "*.tmp" -delete 2>/dev/null
    sudo rm -f /var/lib/flatpak/history 2>/dev/null

    INSTALLED_FLATPAKS=$(flatpak list --app --columns=application 2>/dev/null)
    if [ -d "/var/app" ]; then
        for app_dir in /var/app/*; do
            if [ -d "$app_dir" ]; then
                app_id=$(basename "$app_dir")
                if ! echo "$INSTALLED_FLATPAKS" | grep -qx "$app_id"; then
                    sudo rm -rf "$app_dir"
                fi
            fi
        done
    fi
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo journalctl --vacuum-time=7d
sudo find /var/log -type f -name "*.gz" -mtime +7 -delete
sudo find /var/log -type f -name "*.1" -delete
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo find /tmp -type f -atime +3 -delete 2>/dev/null
sudo find /var/tmp -type f -atime +3 -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

CURRENT_KERNEL=$(uname -r)
KERNEL_PACKAGES=$(dpkg -l | grep -E 'linux-image-[0-9]' | awk '{print $2}' | grep -v "$CURRENT_KERNEL")
if [ -n "$KERNEL_PACKAGES" ]; then
    sudo apt-get purge $KERNEL_PACKAGES -y
    REBOOT_NEEDED=true
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

# ---------------------------------------------------------------
# PHASE: USER CLEANUP
# ---------------------------------------------------------------
find ~/.cache -type f -atime +14 \
    ! -path "*/mozilla/*" \
    ! -path "*/google-chrome/*" \
    ! -path "*/chromium/*" \
    ! -path "*/BraveSoftware/*" \
    ! -path "*/opera/*" \
    -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

find ~/.cache/thumbnails -type f -atime +7 -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

if command -v flatpak &> /dev/null; then
    flatpak uninstall --unused --user -y
    flatpak uninstall --unused --delete-data -y 2>/dev/null || flatpak uninstall --delete-data -y 2>/dev/null
    rm -rf ~/.local/share/flatpak/repo/tmp/* 2>/dev/null
    rm -f ~/.local/share/flatpak/history 2>/dev/null

    INSTALLED_FLATPAKS=$(flatpak list --app --columns=application 2>/dev/null)
    if [ -d "$HOME/.var/app" ]; then
        for app_dir in "$HOME/.var/app"/*; do
            if [ -d "$app_dir" ]; then
                app_id=$(basename "$app_dir")
                if ! echo "$INSTALLED_FLATPAKS" | grep -qx "$app_id"; then
                    rm -rf "$app_dir"
                fi
            fi
        done
    fi
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

fc-cache -fv
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_USER"

USER_ID=$(id -u)
if [ -S "/run/user/$USER_ID/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" dconf reset /org/virt-manager/virt-manager/urls/isos 2>/dev/null
fi
rm -rf "$HOME/.cache/virt-manager" 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_RESTART"

# ---------------------------------------------------------------
# PHASE: RESTART CHECK
# ---------------------------------------------------------------
if [ -f /var/run/reboot-required ]; then
    REBOOT_NEEDED=true
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_RESTART"

if [ "$FWUPD_RESTART_NEEDED" = true ]; then
    REBOOT_NEEDED=true
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_RESTART"

echo -e "\n" >&3
echo -e "${GREEN}======================================================${NC}" >&3
echo -e "${GREEN}${MSG_DONE}${NC}" >&3
echo -e "${GREEN}======================================================${NC}" >&3

if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "${YELLOW}${MSG_RESTART_WARN}${NC}" >&3
    echo -e "${YELLOW}${MSG_PRESS_ENTER}${NC}" >&3
    read -r
else
    echo -e "${GREEN}${MSG_NO_RESTART}${NC}" >&3
fi
