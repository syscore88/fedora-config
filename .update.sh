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
    MSG_TITLE="                  KONSERWACJA SYSTEMU                  "
    MSG_ASK_PASS="Proszę podać hasło administratora (sudo):"
    MSG_PHASE_UPDATE="[1/2] Aktualizacja i optymalizacja..."
    MSG_PHASE_CLEAN_SYS="[2/2] Czyszczenie systemowe..."
    MSG_DONE="             KONSERWACJA SYSTEMU ZAKOŃCZONA!           "
    MSG_RESTART_WARN="UWAGA: Zalecany jest restart komputera"
    MSG_NO_RESTART="Restart systemu nie jest aktualnie wymagany."
    MSG_PRESS_ENTER="Naciśnij Enter, aby zamknąć okno..."
else
    MSG_TITLE="                   SYSTEM MAINTENANCE                   "
    MSG_ASK_PASS="Please enter the administrator (sudo) password:"
    MSG_PHASE_UPDATE="[1/2] Updates and optimization..."
    MSG_PHASE_CLEAN_SYS="[2/2] System cleanup..."
    MSG_DONE="             SYSTEM MAINTENANCE COMPLETE!           "
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

CURRENT_USER=$(whoami)
RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1 || sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

echo -e "${BLUE}======================================================${NC}" >&3
echo -e "${BLUE}${MSG_TITLE}${NC}" >&3
echo -e "${BLUE}======================================================${NC}" >&3
echo -e "${YELLOW}${MSG_ASK_PASS}${NC}" >&3
if [[ -r /dev/tty ]]; then
    IFS= read -rs SUDO_PASSWORD < /dev/tty || true
else
    IFS= read -rs SUDO_PASSWORD || true
fi
echo "" >&3

if [[ "$USE_RUN0" -eq 1 ]]; then
    POLKIT_TMP="$(mktemp)"
    cat > "$POLKIT_TMP" << EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
EOF
    if printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' install -m 0644 -o root -g root "$POLKIT_TMP" "$RUN0_NOPASSWD_FILE" &>/dev/null; then
        printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' systemctl try-restart polkit 2>/dev/null || true
        rm -f "$POLKIT_TMP"
        unset SUDO_PASSWORD
    else
        rm -f "$POLKIT_TMP"
        unset SUDO_PASSWORD
        if [ "$SCRIPT_LANG" = "pl" ]; then
            echo -e "${RED}✘ Nieprawidłowe hasło lub nie udało się nadać uprawnień tymczasowych – przerywam. Jeśli w /etc/sudoers działa opcja targetpw, podaj hasło roota.${NC}" >&3
        else
            echo -e "${RED}✘ Wrong password or failed to grant temporary privileges - aborting. If targetpw is set in /etc/sudoers, enter the root password.${NC}" >&3
        fi
        exit 1
    fi
else
    SUDOERS_TMP="$(mktemp)"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$CURRENT_USER" > "$SUDOERS_TMP"
    if printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' visudo -cf "$SUDOERS_TMP" &>/dev/null \
       && printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-update &>/dev/null; then
        rm -f "$SUDOERS_TMP"
        unset SUDO_PASSWORD
    else
        rm -f "$SUDOERS_TMP"
        unset SUDO_PASSWORD
        if [ "$SCRIPT_LANG" = "pl" ]; then
            echo -e "${RED}✘ Nieprawidłowe hasło lub składnia pliku sudoers – przerywam. Jeśli w /etc/sudoers działa opcja targetpw, podaj hasło roota.${NC}" >&3
        else
            echo -e "${RED}✘ Wrong password or invalid sudoers syntax - aborting. If targetpw is set in /etc/sudoers, enter the root password.${NC}" >&3
        fi
        exit 1
    fi
fi

if ! sudo -n true 2>/dev/null; then
    if [ "$SCRIPT_LANG" = "pl" ]; then
        echo -e "${RED}✘ Nie udało się uzyskać uprawnień bez hasła – przerywam.${NC}" >&3
    else
        echo -e "${RED}✘ Could not obtain passwordless privileges - aborting.${NC}" >&3
    fi
    exit 1
fi

REBOOT_NEEDED=false
FWUPD_RESTART_NEEDED=false
TOTAL_STEPS=15
STEP=0
show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_UPDATE"

# ---------------------------------------------------------------
# PHASE: UPDATE 
# ---------------------------------------------------------------
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
sudo env LC_ALL=C dnf autoremove -y
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo env LC_ALL=C dnf clean packages
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v flatpak &> /dev/null; then
    USED_REMOTES=$(flatpak list --columns=origin 2>/dev/null | sort -u)
    ALL_REMOTES=$(flatpak remotes --columns=name 2>/dev/null)
    while IFS= read -r remote; do
        if [ -n "$remote" ] && ! echo "$USED_REMOTES" | grep -qx "$remote"; then
            sudo flatpak remote-delete --force "$remote" 2>/dev/null
        fi
    done <<< "$ALL_REMOTES"
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo journalctl --vacuum-time=7d
sudo find /var/log -type f -name "*.gz" -mtime +7 -delete
sudo find /var/log -type f -name "*.1" -delete
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

sudo find /tmp -type f -atime +3 -delete 2>/dev/null
sudo find /var/tmp -type f -atime +3 -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

OLD_KERNELS=$(dnf repoquery --installonly --latest-limit=-2 -q 2>/dev/null)
if [ -n "$OLD_KERNELS" ]; then
    sudo env LC_ALL=C dnf remove -y $OLD_KERNELS
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

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
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

find ~/.cache/thumbnails -type f -atime +7 -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

fc-cache -fv
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

USER_ID=$(id -u)
if [ -S "/run/user/$USER_ID/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" dconf reset /org/virt-manager/virt-manager/urls/isos 2>/dev/null
fi
rm -rf "$HOME/.cache/virt-manager" 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: RESTART CHECK
# ---------------------------------------------------------------
if command -v dnf5 &> /dev/null; then
    if ! dnf5 needs-restarting &>/dev/null; then
        REBOOT_NEEDED=true
    fi
elif command -v needs-restarting &> /dev/null; then
    if ! needs-restarting -r &>/dev/null; then
        REBOOT_NEEDED=true
    fi
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if [ "$FWUPD_RESTART_NEEDED" = true ]; then
    REBOOT_NEEDED=true
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if [[ "$USE_RUN0" -eq 1 ]]; then
    sudo rm -f "$RUN0_NOPASSWD_FILE"
    sudo systemctl try-restart polkit 2>/dev/null || true
else
    sudo rm -f /etc/sudoers.d/99-temp-update
fi

echo -e "\n" >&3
echo -e "${GREEN}======================================================${NC}" >&3
echo -e "${GREEN}${MSG_DONE}${NC}" >&3
echo -e "${GREEN}======================================================${NC}" >&3

if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "${YELLOW}${MSG_RESTART_WARN}${NC}" >&3
else
    echo -e "${GREEN}${MSG_NO_RESTART}${NC}" >&3
fi
echo -e "${YELLOW}${MSG_PRESS_ENTER}${NC}" >&3
read -r
