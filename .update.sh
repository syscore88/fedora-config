#!/bin/bash

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DETECTED_LOCALE="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
if [ -z "$DETECTED_LOCALE" ] && command -v locale &> /dev/null; then
    DETECTED_LOCALE=$(locale 2>/dev/null | grep -m1 '^LANG=' | cut -d= -f2)
fi

if [[ "$DETECTED_LOCALE" == pl_PL* ]] || [[ "$DETECTED_LOCALE" == pl* ]]; then
    IS_PL=true
else
    IS_PL=false
fi

if [ "$IS_PL" = true ]; then
    MSG_TITLE="       KOMPLEKSOWY SKRYPT AKTUALIZACJI I CZYSZCZENIA  "
    MSG_ASK_PASS="Proszę podać hasło administratora (sudo):"
    MSG_DNF_UPGRADE="==> Odświeżanie repozytoriów i pełna aktualizacja systemu (DNF)..."
    MSG_FWUPD_CHECK="==> Odświeżanie metadanych i sprawdzanie aktualizacji firmware..."
    MSG_FWUPD_RESTART_NEEDED="UWAGA: Zainstalowano aktualizację firmware wymagającą restartu!"
    MSG_FLATPAK_UPDATE="==> Aktualizacja pakietów Flatpak (System i Użytkownik)..."
    MSG_GNOME_EXT_UPDATE="==> Aktualizacja rozszerzeń GNOME Shell (gext)..."
    MSG_GNOME_EXT_ABSENT="==> gext nieobecny w systemie - pomijam aktualizację rozszerzeń GNOME."
    MSG_CINNAMON_EXT_UPDATE="==> Aktualizacja rozszerzeń/appletów/dekletów/motywów Cinnamon..."
    MSG_CINNAMON_EXT_ABSENT="==> cinnamon-spice-updater nieobecny w systemie - pomijam aktualizację Cinnamon."
    MSG_PHASE1_TITLE="       FAZA 1: SYSTEM (SUDO)                         "
    MSG_AUTOREMOVE="==> Usuwanie niepotrzebnych zależności (Autoremove)..."
    MSG_DNF_CLEAN="==> Czyszczenie cache DNF..."
    MSG_CLEAN_JOURNAL="==> Czyszczenie starych logów Journalctl (starsze niż 7 dni)..."
    MSG_CLEAN_VARLOG="==> Usuwanie starych plików logów (.gz i .1) z /var/log..."
    MSG_FLATPAK_CLEAN_SYS="==> Kompleksowe czyszczenie Flatpak (System)..."
    MSG_FLATPAK_REMOVING_REMOTE="Usuwanie nieużywanego źródła Flatpak:"
    MSG_FLATPAK_TMP_HISTORY_SYS="==> Usuwanie plików .tmp i historii Flatpak (System)..."
    MSG_FLATPAK_CLEAN_VARAPP_SYS="==> Czyszczenie osieroconych danych po usuniętych aplikacjach w /var/app..."
    MSG_FLATPAK_REMOVING_VARAPP_SYS="Usuwanie osieroconych danych systemowych w /var/app:"
    MSG_CLEAN_TMP="==> Czyszczenie /tmp i /var/tmp (starsze niż 3 dni)..."
    MSG_CHECK_ORPHAN_MODULES="==> Sprawdzanie osieroconych modułów kernela..."
    MSG_REMOVING_OLD_KERNEL="Usuwanie pozostałości po starym kernelu:"
    MSG_PHASE2_TITLE="       FAZA 2: UŻYTKOWNIK (BEZ SUDO)                 "
    MSG_CLEAN_USER_CACHE="==> Czyszczenie cache użytkownika (z wyłączeniem przeglądarek)..."
    MSG_CLEAN_THUMBS="==> Czyszczenie starych miniatur (thumbnails)..."
    MSG_FLATPAK_CLEAN_USER="==> Czyszczenie Flatpak (Użytkownik)..."
    MSG_FLATPAK_CLEAN_VARAPP_USER="==> Czyszczenie osieroconych danych po usuniętych aplikacjach w ~/.var/app..."
    MSG_FLATPAK_REMOVING_VARAPP_USER="Usuwanie osieroconych danych użytkownika w ~/.var/app:"
    MSG_REBUILD_FONTS="==> Przebudowa cache czcionek..."
    MSG_CLEAN_VIRT="==> Czyszczenie konfiguracji virt-manager..."
    MSG_PHASE3_TITLE="       FAZA 3: SPRAWDZANIE STANU SYSTEMU             "
    MSG_CHECK_RESTART="==> Sprawdzanie konieczności restartu..."
    MSG_RESTART_WARN1="UWAGA: Zaktualizowano kernel lub kluczowe pakiety!"
    MSG_RESTART_WARN2=" ZALECANY JEST RESTART KOMPUTERA!                     "
    MSG_NO_RESTART_NEEDED="==> Restart systemu nie jest aktualnie wymagany."
    MSG_NO_NEEDS_RESTARTING="Brak wtyczki 'needs-restarting'. Upewnij się, że masz zainstalowany pakiet 'dnf-plugins-core'."
    MSG_DONE_TITLE="       AKTUALIZACJA I CZYSZCZENIE ZAKOŃCZONE!          "
    MSG_PRESS_ENTER="Naciśnij [ENTER], aby zakończyć..."
else
    MSG_TITLE="         COMPREHENSIVE UPDATE AND CLEANUP SCRIPT       "
    MSG_ASK_PASS="Please enter the administrator (sudo) password:"
    MSG_DNF_UPGRADE="==> Refreshing repositories and performing a full system update (DNF)..."
    MSG_FWUPD_CHECK="==> Refreshing metadata and checking for firmware updates..."
    MSG_FWUPD_RESTART_NEEDED="WARNING: A firmware update requiring a restart was installed!"
    MSG_FLATPAK_UPDATE="==> Updating Flatpak packages (System and User)..."
    MSG_GNOME_EXT_UPDATE="==> Updating GNOME Shell extensions (gext)..."
    MSG_GNOME_EXT_ABSENT="==> gext not present on the system - skipping GNOME extensions update."
    MSG_CINNAMON_EXT_UPDATE="==> Updating Cinnamon extensions/applets/desklets/themes..."
    MSG_CINNAMON_EXT_ABSENT="==> cinnamon-spice-updater not present on the system - skipping Cinnamon update."
    MSG_PHASE1_TITLE="       PHASE 1: SYSTEM (SUDO)                        "
    MSG_AUTOREMOVE="==> Removing unnecessary dependencies (Autoremove)..."
    MSG_DNF_CLEAN="==> Cleaning DNF cache..."
    MSG_CLEAN_JOURNAL="==> Cleaning old Journalctl logs (older than 7 days)..."
    MSG_CLEAN_VARLOG="==> Removing old log files (.gz and .1) from /var/log..."
    MSG_FLATPAK_CLEAN_SYS="==> Comprehensive Flatpak cleanup (System)..."
    MSG_FLATPAK_REMOVING_REMOTE="Removing unused Flatpak remote:"
    MSG_FLATPAK_TMP_HISTORY_SYS="==> Removing .tmp files and Flatpak history (System)..."
    MSG_FLATPAK_CLEAN_VARAPP_SYS="==> Cleaning orphaned data from removed apps in /var/app..."
    MSG_FLATPAK_REMOVING_VARAPP_SYS="Removing orphaned system data in /var/app:"
    MSG_CLEAN_TMP="==> Cleaning /tmp and /var/tmp (older than 3 days)..."
    MSG_CHECK_ORPHAN_MODULES="==> Checking for orphaned kernel modules..."
    MSG_REMOVING_OLD_KERNEL="Removing leftovers from old kernel:"
    MSG_PHASE2_TITLE="       PHASE 2: USER (NO SUDO)                       "
    MSG_CLEAN_USER_CACHE="==> Cleaning user cache (excluding browsers)..."
    MSG_CLEAN_THUMBS="==> Cleaning old thumbnails..."
    MSG_FLATPAK_CLEAN_USER="==> Cleaning Flatpak (User)..."
    MSG_FLATPAK_CLEAN_VARAPP_USER="==> Cleaning orphaned data from removed apps in ~/.var/app..."
    MSG_FLATPAK_REMOVING_VARAPP_USER="Removing orphaned user data in ~/.var/app:"
    MSG_REBUILD_FONTS="==> Rebuilding font cache..."
    MSG_CLEAN_VIRT="==> Cleaning virt-manager configuration..."
    MSG_PHASE3_TITLE="       PHASE 3: CHECKING SYSTEM STATE                "
    MSG_CHECK_RESTART="==> Checking if a restart is needed..."
    MSG_RESTART_WARN1="WARNING: The kernel or key packages have been updated!"
    MSG_RESTART_WARN2=" A SYSTEM RESTART IS RECOMMENDED!                     "
    MSG_NO_RESTART_NEEDED="==> A system restart is not currently required."
    MSG_NO_NEEDS_RESTARTING="The 'needs-restarting' plugin is missing. Make sure the 'dnf-plugins-core' package is installed."
    MSG_DONE_TITLE="       UPDATE AND CLEANUP COMPLETE!                    "
    MSG_PRESS_ENTER="Press [ENTER] to finish..."
fi

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

echo -e "${YELLOW}${MSG_ASK_PASS}${NC}"
sudo -v

while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEP_ALIVE_PID=$!

echo -e "\n${GREEN}${MSG_DNF_UPGRADE}${NC}"
sudo dnf upgrade --refresh -y

FWUPD_RESTART_NEEDED=false
if command -v fwupdmgr &> /dev/null; then
    echo -e "${GREEN}${MSG_FWUPD_CHECK}${NC}"
    sudo fwupdmgr refresh -y
    FWUPD_OUT=$(sudo fwupdmgr update -y 2>&1)
    echo "$FWUPD_OUT"

    if echo "$FWUPD_OUT" | grep -qiE "restart|reboot"; then
        FWUPD_RESTART_NEEDED=true
    fi
fi

if command -v flatpak &> /dev/null; then
    echo -e "\n${GREEN}${MSG_FLATPAK_UPDATE}${NC}"
    sudo flatpak update --system -y
    flatpak update --user -y
fi

if command -v gext &> /dev/null; then
    echo -e "\n${GREEN}${MSG_GNOME_EXT_UPDATE}${NC}"
    gext update
else
    echo -e "\n${YELLOW}${MSG_GNOME_EXT_ABSENT}${NC}"
fi

if command -v cinnamon-spice-updater &> /dev/null; then
    echo -e "\n${GREEN}${MSG_CINNAMON_EXT_UPDATE}${NC}"
    cinnamon-spice-updater --update-all
else
    echo -e "\n${YELLOW}${MSG_CINNAMON_EXT_ABSENT}${NC}"
fi

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_PHASE1_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

echo -e "${GREEN}${MSG_AUTOREMOVE}${NC}"
sudo dnf autoremove -y

echo -e "${GREEN}${MSG_DNF_CLEAN}${NC}"
sudo dnf clean all

echo -e "${GREEN}${MSG_CLEAN_JOURNAL}${NC}"
sudo journalctl --vacuum-time=7d

echo -e "${GREEN}${MSG_CLEAN_VARLOG}${NC}"
sudo find /var/log -type f \( -name "*.gz" -o -name "*.1" \) -delete

if command -v flatpak &> /dev/null; then
    echo -e "${GREEN}${MSG_FLATPAK_CLEAN_SYS}${NC}"
    sudo flatpak uninstall --unused --system -y

    sudo flatpak uninstall --unused --delete-data -y 2>/dev/null
    sudo flatpak repair --system

    USED_REMOTES=$(flatpak list --columns=origin 2>/dev/null | sort -u)
    ALL_REMOTES=$(flatpak remotes --columns=name 2>/dev/null | tail -n +1)

    while IFS= read -r remote; do
        if [ -n "$remote" ] && ! echo "$USED_REMOTES" | grep -qx "$remote"; then
            echo -e "${YELLOW}${MSG_FLATPAK_REMOVING_REMOTE} $remote${NC}"
            sudo flatpak remote-delete --force "$remote" 2>/dev/null && \
            sudo rm -rf /var/tmp/flatpak-cache-* 2>/dev/null
        fi
    done <<< "$ALL_REMOTES"

    echo -e "${GREEN}${MSG_FLATPAK_TMP_HISTORY_SYS}${NC}"
    sudo find /var/lib/flatpak -name "*.tmp" -delete 2>/dev/null
    sudo rm -f /var/lib/flatpak/history 2>/dev/null

    echo -e "${GREEN}${MSG_FLATPAK_CLEAN_VARAPP_SYS}${NC}"
    INSTALLED_FLATPAKS=$(flatpak list --app --columns=application 2>/dev/null)
    if [ -d "/var/app" ]; then
        for app_dir in /var/app/*; do
            if [ -d "$app_dir" ]; then
                app_id=$(basename "$app_dir")
                if ! echo "$INSTALLED_FLATPAKS" | grep -qx "$app_id"; then
                    echo -e "${YELLOW}${MSG_FLATPAK_REMOVING_VARAPP_SYS} $app_id${NC}"
                    sudo rm -rf "$app_dir"
                fi
            fi
        done
    fi
fi

echo -e "${GREEN}${MSG_CLEAN_TMP}${NC}"
sudo find /tmp -type f -atime +3 -delete 2>/dev/null
sudo find /var/tmp -type f -atime +3 -delete 2>/dev/null

echo -e "${GREEN}${MSG_CHECK_ORPHAN_MODULES}${NC}"
CURRENT_KERNEL=$(uname -r)
for module_dir in /usr/lib/modules/*; do
    if [ -d "$module_dir" ]; then
        version=$(basename "$module_dir")
        if [ "$version" != "$CURRENT_KERNEL" ] && [ ! -f "/boot/vmlinuz-$version" ]; then
            echo "$MSG_REMOVING_OLD_KERNEL $version"
            sudo rm -rf "$module_dir"
        fi
    fi
done

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_PHASE2_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

echo -e "${GREEN}${MSG_CLEAN_USER_CACHE}${NC}"
find ~/.cache -type f -atime +14 \
    ! -path "*/mozilla/*" \
    ! -path "*/google-chrome/*" \
    ! -path "*/chromium/*" \
    ! -path "*/BraveSoftware/*" \
    ! -path "*/opera/*" \
    -exec rm -f {} + 2>/dev/null

echo -e "${GREEN}${MSG_CLEAN_THUMBS}${NC}"
find ~/.cache/thumbnails -type f -atime +7 -exec rm -f {} + 2>/dev/null

if command -v flatpak &> /dev/null; then
    echo -e "${GREEN}${MSG_FLATPAK_CLEAN_USER}${NC}"
    flatpak uninstall --unused --user -y

    flatpak uninstall --unused --delete-data -y 2>/dev/null || flatpak uninstall --delete-data -y 2>/dev/null
    flatpak repair --user

    rm -f ~/.local/share/flatpak/history 2>/dev/null

    echo -e "${GREEN}${MSG_FLATPAK_CLEAN_VARAPP_USER}${NC}"
    INSTALLED_FLATPAKS=$(flatpak list --app --columns=application 2>/dev/null)
    if [ -d "$HOME/.var/app" ]; then
        for app_dir in "$HOME/.var/app"/*; do
            if [ -d "$app_dir" ]; then
                app_id=$(basename "$app_dir")
                if ! echo "$INSTALLED_FLATPAKS" | grep -qx "$app_id"; then
                    echo -e "${YELLOW}${MSG_FLATPAK_REMOVING_VARAPP_USER} $app_id${NC}"
                    rm -rf "$app_dir"
                fi
            fi
        done
    fi
fi

echo -e "${GREEN}${MSG_REBUILD_FONTS}${NC}"
fc-cache -r

echo -e "${GREEN}${MSG_CLEAN_VIRT}${NC}"
USER_ID=$(id -u)
if [ -S "/run/user/$USER_ID/bus" ]; then
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" dconf reset /org/virt-manager/virt-manager/urls/isos 2>/dev/null
fi
rm -rf "$HOME/.cache/virt-manager" 2>/dev/null

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}${MSG_PHASE3_TITLE}${NC}"
echo -e "${BLUE}======================================================${NC}"

echo -e "${GREEN}${MSG_CHECK_RESTART}${NC}"
if dnf help needs-restarting &> /dev/null; then
    if ! sudo dnf needs-restarting -r -q; then
        echo -e "\n${RED}******************************************************${NC}"
        echo -e "${RED} ${MSG_RESTART_WARN1} ${NC}"
        echo -e "${YELLOW}${MSG_RESTART_WARN2}${NC}"
        echo -e "${RED}******************************************************${NC}\n"
    else
        echo -e "${GREEN}${MSG_NO_RESTART_NEEDED}${NC}"
    fi
else
    echo -e "${YELLOW}${MSG_NO_NEEDS_RESTARTING}${NC}"
fi

if [ "$FWUPD_RESTART_NEEDED" = true ]; then
    echo -e "\n${RED}******************************************************${NC}"
    echo -e "${RED} ${MSG_FWUPD_RESTART_NEEDED} ${NC}"
    echo -e "${YELLOW}${MSG_RESTART_WARN2}${NC}"
    echo -e "${RED}******************************************************${NC}\n"
fi

kill $SUDO_KEEP_ALIVE_PID 2>/dev/null

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}${MSG_DONE_TITLE}${NC}"
echo -e "${GREEN}======================================================${NC}"
echo "$MSG_PRESS_ENTER"
read -r
