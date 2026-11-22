#!/bin/bash
set -uo pipefail

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[1;33m'
ERR='\033[0;31m'
NC='\033[0m'

detect_lang() {
    local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    if [ -z "$l" ] && command -v locale &> /dev/null; then
        l=$(locale 2>/dev/null | grep -m1 '^LANG=' | cut -d= -f2)
    fi
    l="${l//\"/}"
    l="${l//\'/}"
    case "$l" in
        pl*) echo "pl" ;;
        *) echo "en" ;;
    esac
}
SCRIPT_LANG=$(detect_lang)

if [ "$SCRIPT_LANG" = "pl" ]; then
    MSG_TITLE="                  KONSERWACJA SYSTEMU                 "
    MSG_ASK_PASS="     Proszę podać hasło administratora (sudo):     "
    MSG_PHASE_CLEAN_SYS="Czyszczenie..."
    MSG_DONE="             KONSERWACJA SYSTEMU ZAKOŃCZONA!           "
    MSG_PRESS_ENTER="     Naciśnij Enter, aby zamknąć okno...        "
else
    MSG_TITLE="                 SYSTEM MAINTENANCE                   "
    MSG_ASK_PASS="     Please enter the administrator (sudo) password: "
    MSG_PHASE_CLEAN_SYS="Cleanup..."
    MSG_DONE="             SYSTEM MAINTENANCE COMPLETE!              "
    MSG_PRESS_ENTER="     Press Enter to close this window...        "
fi

TMP_LOG="$(mktemp /tmp/update-log.XXXXXX)"
LOG_FILE="$HOME/update_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

PRIVS_GRANTED=0
CURRENT_USER=$(whoami)
RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
ELEVATE="sudo"
if command -v run0 >/dev/null 2>&1 && { ! command -v visudo >/dev/null 2>&1 || sudo --version 2>/dev/null | grep -qi "run0"; }; then
    USE_RUN0=1
    ELEVATE="run0"
fi

remove_temp_privs() {
    [[ "$PRIVS_GRANTED" -eq 1 ]] || return 0
    if [[ "$USE_RUN0" -eq 1 ]]; then
        run0 rm -f "$RUN0_NOPASSWD_FILE" 2>/dev/null || true
        run0 systemctl try-restart polkit 2>/dev/null || true
    else
        sudo -n rm -f /etc/sudoers.d/99-temp-update 2>/dev/null || true
    fi
    PRIVS_GRANTED=0
}

cleanup_on_exit() {
    local exit_code=$?
    remove_temp_privs
    printf '\033[?25h' >&3
    echo "" >&3
    if [ "$exit_code" -ne 0 ]; then
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$SCRIPT_LANG" = "pl" ]; then
            echo -e "${ERR}[X] Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
        else
            echo -e "${ERR}[X] An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
        fi
    else
        rm -f "$LOG_FILE"
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

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ "$filled" -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ "$empty" -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    if (( avail >= 4 )); then
        if (( ${#msg} > avail )); then
            msg="${msg:0:$((avail - 3))}..."
        fi
        printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
    else
        printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%%" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
    fi
}

cleanup_stale_privs() {
    if [[ "$USE_RUN0" -eq 0 ]]; then
        sudo -n true 2>/dev/null || return 0
        sudo -n rm -f /etc/sudoers.d/99-temp-update 2>/dev/null || true
    fi
}
cleanup_stale_privs

echo -e "${INFO}======================================================${NC}" >&3
echo -e "${INFO}${MSG_TITLE}${NC}" >&3
echo -e "${INFO}======================================================${NC}" >&3

if [[ "$USE_RUN0" -eq 1 ]]; then
    POLKIT_TMP="$(mktemp)"
    cat > "$POLKIT_TMP" << EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
EOF
    if { [[ -r /dev/tty ]] && run0 install -m 0644 -o root -g root "$POLKIT_TMP" "$RUN0_NOPASSWD_FILE" </dev/tty >&3 2>&3; } \
       || { [[ ! -r /dev/tty ]] && run0 install -m 0644 -o root -g root "$POLKIT_TMP" "$RUN0_NOPASSWD_FILE" >&3 2>&3; }; then
        PRIVS_GRANTED=1
        run0 systemctl try-restart polkit 2>/dev/null || true
        rm -f "$POLKIT_TMP"
    else
        rm -f "$POLKIT_TMP"
        if [ "$SCRIPT_LANG" = "pl" ]; then
            echo -e "${ERR}[X] Nieprawidłowe hasło lub nie udało się nadać uprawnień tymczasowych (run0) – przerywam.${NC}" >&3
        else
            echo -e "${ERR}[X] Wrong password or failed to grant temporary privileges (run0) - aborting.${NC}" >&3
        fi
        exit 1
    fi
else
    echo -e "${WARN}${MSG_ASK_PASS}${NC}" >&3
    if [[ -r /dev/tty ]]; then
        IFS= read -rs SUDO_PASSWORD < /dev/tty || true
    else
        IFS= read -rs SUDO_PASSWORD || true
    fi
    echo "" >&3

    SUDOERS_TMP="$(mktemp)"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$CURRENT_USER" > "$SUDOERS_TMP"
    if printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' visudo -cf "$SUDOERS_TMP" &>/dev/null \
       && printf '%s\n' "${SUDO_PASSWORD:-}" | sudo -S -p '' install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-update &>/dev/null; then
        PRIVS_GRANTED=1
        rm -f "$SUDOERS_TMP"
        unset SUDO_PASSWORD
        if ! sudo -n true 2>/dev/null; then
            if [ "$SCRIPT_LANG" = "pl" ]; then
                echo -e "${WARN}[!] Reguła NOPASSWD zainstalowana, ale sudo nadal prosi o hasło - sprawdź 'sudo -l' (możliwa inna reguła w /etc/sudoers nadpisująca wpis z sudoers.d).${NC}" >&3
            else
                echo -e "${WARN}[!] NOPASSWD rule installed, but sudo still asks for a password - check 'sudo -l' (a rule in /etc/sudoers may be overriding the sudoers.d entry).${NC}" >&3
            fi
        fi
    else
        rm -f "$SUDOERS_TMP"
        unset SUDO_PASSWORD
        if [ "$SCRIPT_LANG" = "pl" ]; then
            echo -e "${ERR}[X] Nieprawidłowe hasło lub składnia pliku sudoers – przerywam. Jeśli w /etc/sudoers działa opcja targetpw, podaj hasło roota.${NC}" >&3
        else
            echo -e "${ERR}[X] Wrong password or invalid sudoers syntax - aborting. If targetpw is set in /etc/sudoers, enter the root password.${NC}" >&3
        fi
        exit 1
    fi

    if ! sudo -n true 2>/dev/null; then
        if [ "$SCRIPT_LANG" = "pl" ]; then
            echo -e "${ERR}[X] Nie udało się uzyskać uprawnień bez hasła – przerywam.${NC}" >&3
        else
            echo -e "${ERR}[X] Could not obtain passwordless privileges - aborting.${NC}" >&3
        fi
        exit 1
    fi
fi

TOTAL_STEPS=12
STEP=0
printf '\033[?25l' >&3
show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: DESKTOP EXTENSIONS AND FIRMWARE
# ---------------------------------------------------------------
if command -v gext &> /dev/null; then
    gext update
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v cinnamon-spice-updater &> /dev/null; then
    cinnamon-spice-updater --update-all
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v fwupdmgr &> /dev/null; then
    "$ELEVATE" fwupdmgr refresh --force
    "$ELEVATE" fwupdmgr update -y
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# PHASE: SYSTEM CLEANUP (SUDO)
# ---------------------------------------------------------------
"$ELEVATE" env LC_ALL=C dnf autoremove -y
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

if command -v flatpak &> /dev/null; then
    "$ELEVATE" flatpak uninstall --unused --system --delete-data -y
    "$ELEVATE" flatpak repair --system
    flatpak uninstall --unused --user --delete-data -y
    flatpak repair --user
    rm -rf ~/.local/share/flatpak/repo/tmp/* 2>/dev/null
    rm -f ~/.local/share/flatpak/history 2>/dev/null

    INSTALLED_FLATPAKS=$(flatpak list --app --columns=application 2>/dev/null)
    if [ -n "$INSTALLED_FLATPAKS" ] && [ -d "$HOME/.var/app" ]; then
        for app_dir in "$HOME/.var/app"/*; do
            if [ -d "$app_dir" ]; then
                app_id=$(basename "$app_dir")
                if ! echo "$INSTALLED_FLATPAKS" | grep -qxF -- "$app_id"; then
                    rm -rf "$app_dir"
                fi
            fi
        done
    fi

    USED_REMOTES=$(flatpak list --system --columns=origin 2>/dev/null | sort -u)
    ALL_REMOTES=$(flatpak remotes --system --columns=name 2>/dev/null)
    while IFS= read -r remote; do
        if [ -n "$remote" ] && [ "$remote" != "flathub" ] && [ "$remote" != "fedora" ] && ! echo "$USED_REMOTES" | grep -qxF -- "$remote"; then
            "$ELEVATE" flatpak remote-delete --system --force "$remote" 2>/dev/null
        fi
    done <<< "$ALL_REMOTES"

    "$ELEVATE" rm -rf /var/tmp/flatpak-cache-* 2>/dev/null
    "$ELEVATE" rm -rf /var/lib/flatpak/repo/tmp/* 2>/dev/null
    "$ELEVATE" find /var/lib/flatpak -name "*.tmp" -delete 2>/dev/null
    "$ELEVATE" rm -f /var/lib/flatpak/history 2>/dev/null
fi
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

"$ELEVATE" journalctl --vacuum-time=7d
"$ELEVATE" find /var/log -type f -name "*.gz" -mtime +7 -delete
"$ELEVATE" find /var/log -type f -name "*.1" -delete
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

"$ELEVATE" find /tmp -xdev -type f -atime +3 \
    ! -path "/tmp/systemd-private-*" \
    ! -path "/tmp/.*" \
    -delete 2>/dev/null
"$ELEVATE" find /var/tmp -xdev -type f -atime +3 \
    ! -path "/var/tmp/systemd-private-*" \
    ! -path "/var/tmp/.*" \
    -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

RUNNING_KERNEL="$(uname -r)"
RUNNING_KERNEL="${RUNNING_KERNEL%%+*}"
mapfile -t OLD_KERNELS < <(dnf repoquery --disablerepo='*' --installonly --latest-limit=-2 -q 2>/dev/null | grep -vF -- "$RUNNING_KERNEL")
if (( ${#OLD_KERNELS[@]} > 0 )); then
    "$ELEVATE" env LC_ALL=C dnf remove -y "${OLD_KERNELS[@]}"
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
    ! -path "*/vivaldi/*" \
    ! -path "*/huggingface/*" \
    ! -path "*/torch/*" \
    ! -path "*/ms-playwright/*" \
    -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

find ~/.cache/thumbnails -type f -atime +7 -delete 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

fc-cache -r
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

USER_ID=$(id -u)
if command -v dconf &> /dev/null && [ -S "/run/user/$USER_ID/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" dconf reset /org/virt-manager/virt-manager/urls/isos 2>/dev/null
fi
rm -rf "$HOME/.cache/virt-manager" 2>/dev/null
STEP=$((STEP+1)); show_progress $STEP $TOTAL_STEPS "$MSG_PHASE_CLEAN_SYS"

# ---------------------------------------------------------------
# REMOVE TEMPORARY PRIVILEGES
# ---------------------------------------------------------------
remove_temp_privs

echo -e "\n" >&3
echo -e "${SUCCESS}======================================================${NC}" >&3
echo -e "${SUCCESS}${MSG_DONE}${NC}" >&3
echo -e "${SUCCESS}======================================================${NC}" >&3
echo -e "${WARN}${MSG_PRESS_ENTER}${NC}" >&3
if [[ -r /dev/tty ]]; then
    read -r < /dev/tty || true
else
    read -r || true
fi