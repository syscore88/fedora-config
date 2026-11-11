#!/bin/bash
# =========================================
# KOMPLEKSOWY SKRYPT KONFIGURACYJNY Fedora
# =========================================

set -Eeuo pipefail
export PATH="/usr/sbin:/sbin:$PATH"

detect_system_lang() {
    local sys_lang="${LANG:-}"
    [[ -z "$sys_lang" ]] && sys_lang="${LC_ALL:-${LC_MESSAGES:-}}"
    if [[ "$sys_lang" == pl* ]]; then
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

TMP_LOG="$(mktemp /tmp/fedora-install-log.XXXXXX)"
LOG_FILE="$HOME/install_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

cleanup_on_exit() {
    local exit_code=$?
    declare -F restore_packagekit >/dev/null && restore_packagekit || true
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}[X] Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${ERR}[X] An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
            fi
        fi
    fi
    rm -f "$TMP_LOG"
    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        sudo sh -c 'rm -f "$1" "$2"; systemctl try-restart polkit 2>/dev/null; if [ "$3" = 1 ]; then systemctl reboot; fi' _ \
            "${RUN0_NOPASSWD_FILE:-/etc/polkit-1/rules.d/51-run0-nopasswd.rules}" \
            "/etc/sudoers.d/99-temp-installer" \
            "$do_reboot"
    fi
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() { printf "\r\033[K" >&3; echo -e "$1" >&3; echo -e "$1"; cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true; }
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}[OK] $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}[X] ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}[!] WARN: $m${NC}"; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

# ==========================================================
# PACKAGEKIT + BLOKADA DNF/RPM
# ==========================================================
PACKAGEKIT_MASKED=0
PACKAGEKIT_UNITS=(
    packagekit.service packagekit-offline-update.service
    dnf-makecache.timer dnf-makecache.service
    dnf5-makecache.timer dnf5-makecache.service
)

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

_rpm_lock_busy() {
    local f
    for f in /var/lib/rpm/.rpm.lock /usr/lib/sysimage/rpm/.rpm.lock \
             /var/cache/dnf/metadata_lock.pid; do
        [[ -e "$f" ]] || continue
        sudo fuser "$f" >/dev/null 2>&1 && return 0
    done
    pgrep -x 'dnf|dnf5|dnf-automatic|rpm|packagekitd' >/dev/null 2>&1 && return 0
    return 1
}

wait_for_rpm_lock() {
    local timeout="${1:-300}" waited=0
    disable_packagekit
    while _rpm_lock_busy; do
        if (( waited >= timeout )); then
            log_warn "Blokada dnf/rpm trwa ponad ${timeout}s - próbuję ją zwolnić." \
                     "dnf/rpm lock held for over ${timeout}s - trying to release it."
            sudo killall -q packagekitd 2>/dev/null || sudo pkill -x packagekitd 2>/dev/null || true
            if pgrep -x 'dnf|dnf5|rpm' >/dev/null 2>&1; then
                log_warn "Transakcja dnf/rpm wciąż trwa - nie ruszam plików blokady, kontynuuję." \
                         "A dnf/rpm transaction is still running - leaving the lock files alone, continuing."
            else
                sudo rm -f /var/cache/dnf/metadata_lock.pid /var/cache/libdnf5/*.lock 2>/dev/null || true
            fi
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
        msg="${msg:0:$((avail - 3))}..."
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
    MSG_PHASE_1="[1/4] Przygotowywanie..."
    MSG_PHASE_2="[2/4] Instalacja..."
    MSG_PHASE_3="[3/4] Optymalizacja..."
    MSG_PHASE_4="[4/4] Finalizowanie..."
else
    MSG_PHASE_1="[1/4] Preparing..."
    MSG_PHASE_2="[2/4] Installing..."
    MSG_PHASE_3="[3/4] Optimizing..."
    MSG_PHASE_4="[4/4] Finalizing..."
fi

TOTAL_STEPS=12
FAILED_PACKAGES=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CURRENT_USER=$(whoami)
RPM_DIR="/tmp/rpms_$$"

if [[ "$EUID" -eq 0 ]]; then
    echo -e "${ERR}[X] Nie uruchamiaj skryptu jako root. Użyj zwykłego użytkownika z sudo.${NC}" >&3
    exit 1
fi

printf '\033[?7h\n' >&3

RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1 || sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

SUDO_READY=0
if [[ "$USE_RUN0" -eq 1 ]]; then
    sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null << EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
EOF
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
        echo "%wheel ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
        sudo visudo -cf "$SUDOERS_TMP" &>/dev/null && sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99_nopasswd || true
    else
        rm -f "$SUDOERS_TMP"
        echo -e "${ERR}[X] Nieprawidłowa składnia pliku sudoers – przerywam.${NC}" >&3
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
    SUDO_READY=1
fi

printf '\033[?7l' >&3

wait_for_rpm_lock() {
    local i=0
    while pgrep -x dnf >/dev/null || pgrep -x dnf5 >/dev/null || pgrep -x packagekitd >/dev/null || pgrep -x rpm >/dev/null; do
        if (( i++ >= 24 )); then
            sudo systemctl stop packagekit.service dnf-makecache.service dnf5-makecache.service 2>/dev/null || true
            sudo killall -9 dnf dnf5 rpm packagekitd 2>/dev/null || true
            sudo rm -f /var/lib/rpm/.rpm.lock /usr/lib/sysimage/rpm/.rpm.lock /var/cache/libdnf5/*.lock 2>/dev/null || true
            break
        fi
        sleep 5
    done
}

install_missing() {
    local -a opts=() missing=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == -* ]]; then
            opts+=("$arg")
        elif [[ "$arg" == @* ]] || ! rpm -q "$arg" &>/dev/null; then
            missing+=("$arg")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        sudo dnf5 install "${opts[@]}" "${missing[@]}"
    fi
}

pkg_installed() {
    rpm -q "$1" &>/dev/null
}

install_dnf_pkgs() {
    wait_for_rpm_lock
    install_missing "$@" || true
    local arg
    for arg in "$@"; do
        [[ "$arg" == -* || "$arg" == @* ]] && continue
        pkg_installed "$arg" || FAILED_PACKAGES+=("$arg")
    done
}

# ==========================================================
#  ETAP 1/4: PRZYGOTOWYWANIE
# ==========================================================
show_progress 0 $TOTAL_STEPS "$MSG_PHASE_1"

if [ -f "$SCRIPT_DIR/.update.sh" ]; then
    cp -af "$SCRIPT_DIR/.update.sh" ~/.update.sh
    chmod +x ~/.update.sh
fi

if [ -d "$SCRIPT_DIR/.local" ]; then
    mkdir -p ~/.local
    cp -afT "$SCRIPT_DIR/.local" ~/.local
fi

if [ -d "$SCRIPT_DIR/.config" ]; then
    mkdir -p ~/.config
    cp -afT "$SCRIPT_DIR/.config" ~/.config
fi

show_progress 1 $TOTAL_STEPS "$MSG_PHASE_1"

sudo systemctl stop packagekit.service packagekit-offline-update.service dnf-makecache.timer dnf-makecache.service dnf5-makecache.timer dnf5-makecache.service 2>/dev/null || true
sudo systemctl mask packagekit.service packagekit-offline-update.service dnf-makecache.timer dnf-makecache.service dnf5-makecache.timer dnf5-makecache.service 2>/dev/null || true
sudo killall -9 packagekitd dnf dnf5 rpm 2>/dev/null || true
disable_packagekit

for DNF_CONF in /etc/dnf/dnf.conf /etc/dnf/dnf5.conf; do
    if [[ -f "$DNF_CONF" ]]; then
        sudo sed -i '/^fastestmirror=/d; /^retries=/d; /^timeout=/d; /^max_parallel_downloads=/d; /^ip_resolve=/d' "$DNF_CONF"
        echo -e "fastestmirror=False\nmax_parallel_downloads=10\nretries=10\ntimeout=120\nip_resolve=4" | sudo tee -a "$DNF_CONF" > /dev/null
    fi
done

wait_for_rpm_lock
for pkg in wget curl pciutils dconf; do
    install_missing -y "$pkg" || true
done

GPU_TYPE="unknown"
HYBRID_GPU=false
GPU_VENDORS=()
GPU_UNKNOWN_PKGS=(
    mesa-dri-drivers.x86_64 mesa-dri-drivers.i686 mesa-vulkan-drivers.x86_64 mesa-vulkan-drivers.i686
    mesa-libGL.x86_64 mesa-libGL.i686 vulkan-headers vulkan-loader-devel vulkan-tools
    mesa-libOpenCL.x86_64
)
if command -v lspci &>/dev/null; then
    GPU_INFO=$(lspci | grep -i -E "vga|3d|display" || true)

    echo "$GPU_INFO" | grep -qi "nvidia"      && GPU_VENDORS+=("nvidia")
    echo "$GPU_INFO" | grep -qi -E "\b(amd|ati)\b|advanced micro devices|radeon" && GPU_VENDORS+=("amd")
    echo "$GPU_INFO" | grep -qi "intel"       && GPU_VENDORS+=("intel")

    TOTAL_KNOWN=${#GPU_VENDORS[@]}

    if [ -z "$GPU_INFO" ] || [ "$TOTAL_KNOWN" -eq 0 ]; then
        HYBRID_GPU=false
        for pkg in "${GPU_UNKNOWN_PKGS[@]}"; do
            pkg_installed "$pkg" || install_missing -y --skip-unavailable "$pkg" || true
        done
    elif [ "$TOTAL_KNOWN" -ge 2 ]; then
        HYBRID_GPU=true
        GPU_TYPE="$(IFS=+; echo "${GPU_VENDORS[*]}")"
        log_info "Wykryto hybrydowy układ graficzny (HYBRID_GPU=$HYBRID_GPU): $GPU_TYPE" "Detected a hybrid GPU setup (HYBRID_GPU=$HYBRID_GPU): $GPU_TYPE"
    else
        HYBRID_GPU=false
        GPU_TYPE="${GPU_VENDORS[0]}"
    fi
else
    for pkg in "${GPU_UNKNOWN_PKGS[@]}"; do
        pkg_installed "$pkg" || install_missing -y --skip-unavailable "$pkg" || true
    done
fi

show_progress 2 $TOTAL_STEPS "$MSG_PHASE_1"

FEDORA_VER=$(rpm -E %fedora)
wait_for_rpm_lock
RPMFUSION_URLS=()
rpm -q rpmfusion-free-release &>/dev/null || RPMFUSION_URLS+=("https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm")
rpm -q rpmfusion-nonfree-release &>/dev/null || RPMFUSION_URLS+=("https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm")
if (( ${#RPMFUSION_URLS[@]} > 0 )); then
    sudo dnf5 install -y --no-gpgchecks "${RPMFUSION_URLS[@]}" || true
fi

    wait_for_rpm_lock
sudo dnf5 makecache --refresh || true

OLD_GOOGLE_KEYS=$(rpm -qa 'gpg-pubkey*' --qf '%{NAME}-%{VERSION}-%{RELEASE} %{PACKAGER}\n' 2>/dev/null \
    | grep -i 'linux-packages-keymaster@google.com\|Google, Inc' \
    | cut -d' ' -f1 || true)
if [[ -n "$OLD_GOOGLE_KEYS" ]]; then
    sudo rpm -e $OLD_GOOGLE_KEYS 2>/dev/null || true
fi
sudo rpm --import https://dl.google.com/linux/linux_signing_key.pub || true

sudo tee /etc/yum.repos.d/google-chrome.repo > /dev/null <<'EOF'
[google-chrome]
name=Google Chrome
baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF

wait_for_rpm_lock
for pkg in dnf-plugins-core gnupg2; do
    install_missing -y "$pkg" || true
done

BRAVE_KEY_ID="0686B78420038257"
if ! sudo rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc 2>/dev/null; then
    BRAVE_GNUPGHOME="$(mktemp -d)"
    if ! gpg --homedir "$BRAVE_GNUPGHOME" --keyserver hkps://keyserver.ubuntu.com --recv-keys "$BRAVE_KEY_ID" 2>/dev/null; then
        gpg --homedir "$BRAVE_GNUPGHOME" --keyserver hkps://keys.openpgp.org --recv-keys "$BRAVE_KEY_ID" || true
    fi
    gpg --homedir "$BRAVE_GNUPGHOME" --armor --export "$BRAVE_KEY_ID" > "$BRAVE_GNUPGHOME/brave-core.asc" 2>/dev/null || true
    sudo rpm --import "$BRAVE_GNUPGHOME/brave-core.asc" 2>/dev/null || true
    rm -rf "$BRAVE_GNUPGHOME"
fi

wait_for_rpm_lock
sudo dnf5 config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo || true

sudo mkdir -p /etc/NetworkManager/conf.d
echo -e "[main]\ndns=default\nrc-manager=symlink" | sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null
echo -e "[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002" | sudo tee /etc/NetworkManager/conf.d/global-dns.conf > /dev/null

ACTIVE_CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -v "^lo" | head -n 1 | cut -d: -f1 || true)
if [[ -n "$ACTIVE_CONN" ]]; then
    sudo nmcli connection modify "$ACTIVE_CONN" ipv4.dns "1.1.1.2,1.0.0.2" ipv6.dns "2606:4700:4700::1112,2606:4700:4700::1002"
    sudo nmcli connection up "$ACTIVE_CONN" || true
fi

show_progress 3 $TOTAL_STEPS "$MSG_PHASE_1"

wait_for_rpm_lock
install_missing -y @development-tools @c-development gcc gcc-c++ make || true

TO_REMOVE=(
    konqueror plasma-browser-integration plasma-vault cosmic-player pragha 
    plasma-thunderbolt kontact kmail kontrast plasma-welcome showtime elisa-player 
    rhythmbox dragon exaile mpv kwalletmanager5 gnome-music totem juk yelp 
    evolution-bogofilter evolution-spamassassin evolution evolution-ews evolution-data-server
    kaddressbook kdepim-runtime akonadi-server akregator korganizer parole 
    epiphany decibels gnome-calendar gnome-clocks gnome-user-docs transmission-qt
    gnome-contacts gnome-maps gnome-weather transmission-gtk 
)
wait_for_rpm_lock
for pkg in "${TO_REMOVE[@]}"; do
    sudo dnf5 remove -y "$pkg" 2>/dev/null || true
done
sudo dnf5 autoremove -y || true

rm -rf ~/.local/share/akonadi ~/.local/share/kmail2 ~/.local/share/local-mail ~/.local/share/contacts ~/.local/share/korganizer ~/.local/share/akregator ~/.local/share/kontact ~/.local/share/konqueror
rm -rf ~/.config/akonadi* ~/.config/kmail* ~/.config/kontact* ~/.config/korganizer* ~/.config/kaddressbook* ~/.config/akregator* ~/.config/emailidentities ~/.config/mailtransports
rm -rf ~/.cache/akonadi* ~/.cache/kmail* ~/.cache/kontact* ~/.cache/korganizer* ~/.cache/kaddressbook* ~/.cache/akregator* ~/.cache/konqueror*
rm -rf ~/.local/share/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,evolution,gnome-music,parole,rhythmbox,showtime,epiphany,decibels,dragonplayer,elisa,cosmic-player,transmission,pragha,totem,exaile,mpv,juk}
rm -rf ~/.config/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,evolution,gnome-music,parole,rhythmbox,showtime,epiphany,decibels,dragonplayer,elisa,cosmic-player,transmission,pragha,totem,exaile,mpv,juk}
rm -rf ~/.cache/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,evolution,gnome-music,parole,rhythmbox,showtime,epiphany,decibels,dragonplayer,elisa,cosmic-player,transmission,pragha,totem,exaile,mpv,juk}

if rpm -q plasma-desktop &>/dev/null || rpm -q plasma-workspace &>/dev/null; then
    mkdir -p ~/.config
    cat > ~/.config/kwalletrc << 'EOF'
[Wallet]
Close When Idle=false
Close on Screensaver=false
Default Wallet=kdewallet
Enabled=false
First Use=false
Idle Timeout=10
Launch Manager=false
Leave Manager Open=false
Leave Open=true
Prompt on Open=false
Use One Wallet=true

[org.freedesktop.secrets]
apiEnabled=false
EOF
fi

# ==========================================================
#  ETAP 2/4: INSTALACJA
# ==========================================================
show_progress 4 $TOTAL_STEPS "$MSG_PHASE_2"

SYSTEM_PKGS=(
    google-chrome-stable brave-origin
    dconf-editor hunspell-pl fastfetch unrar git mc exfatprogs ntfs-3g vim-enhanced
    os-prober android-tools fsarchiver inxi pv rsync python3-defusedxml ghostwriter
    python3-packaging python3-pip pipx 7zip zenity innoextract makeself
    bleachbit timeshift vlc vlc-plugins-extra
    audacity gimp gmic gmic-gimp mixxx kdenlive soundconverter HandBrake-gui
    telegram-desktop qbittorrent qmmp pkgconf-pkg-config gnome-disk-utility
    wine winetricks gamemode gamescope mangohud
    cmake meson ninja-build python3-tqdm just gcc-c++ clang llvm mesa-libGL-devel 
    bluez-tools zsh zsh-syntax-highlighting zsh-autosuggestions
)

PKGS_32BIT=(
    glibc.i686 libstdc++.i686 libgcc.i686 vulkan-loader.i686
    alsa-lib.i686 alsa-plugins-pulseaudio.i686 pipewire-alsa.i686 pipewire-libs.i686
    pulseaudio-libs.i686 openal-soft.i686 mangohud.i686 gamemode.i686
    openssl-libs.i686 nss.i686 nspr.i686 libXcomposite.i686 libXcursor.i686
    libXdamage.i686 libXext.i686 libXfixes.i686 libXi.i686 libXrandr.i686
    libXrender.i686 libXtst.i686 libxkbcommon.i686
)

PKGS_CODECS=(
    ffmpeg x264 gstreamer1-libav gstreamer1-plugins-bad-freeworld gstreamer1-plugins-good
    gstreamer1-plugins-bad-free gstreamer1-plugins-ugly
)

for vendor in "${GPU_VENDORS[@]}"; do
    case "$vendor" in
        "nvidia") SYSTEM_PKGS+=(libva-nvidia-driver.x86_64 libva-nvidia-driver.i686 xorg-x11-drv-nvidia-cuda-libs.x86_64 xorg-x11-drv-nvidia-cuda-libs.i686) ;;
        "amd")    SYSTEM_PKGS+=(mesa-dri-drivers.x86_64 mesa-dri-drivers.i686 mesa-vulkan-drivers.x86_64 mesa-vulkan-drivers.i686 mesa-libGL.x86_64 mesa-libGL.i686 vulkan-headers vulkan-loader-devel vulkan-tools mesa-va-drivers-freeworld.x86_64 mesa-va-drivers-freeworld.i686 mesa-libOpenCL.x86_64) ;;
        "intel")  SYSTEM_PKGS+=(mesa-dri-drivers.x86_64 mesa-dri-drivers.i686 mesa-vulkan-drivers.x86_64 mesa-vulkan-drivers.i686 mesa-libGL.x86_64 mesa-libGL.i686 vulkan-headers vulkan-loader-devel vulkan-tools intel-media-driver intel-compute-runtime) ;;
    esac
done

if [ "${#GPU_VENDORS[@]}" -gt 0 ]; then
    readarray -t SYSTEM_PKGS < <(printf '%s\n' "${SYSTEM_PKGS[@]}" | awk '!seen[$0]++')
fi

install_dnf_pkgs -y --refresh --skip-unavailable "${SYSTEM_PKGS[@]}"
install_dnf_pkgs -y --refresh --skip-unavailable "${PKGS_32BIT[@]}"
install_dnf_pkgs -y --allowerasing --skip-unavailable "${PKGS_CODECS[@]}"

if [[ $GPU_TYPE == *"amd"* ]]; then
    install_dnf_pkgs -y --allowerasing --skip-unavailable mesa-vulkan-drivers-freeworld.x86_64 mesa-vulkan-drivers-freeworld.i686
fi

DRACUT_CONF="/etc/dracut.conf.d/90-gpu.conf"
FORCE_DRIVERS=""
if [[ $GPU_TYPE == *"nvidia"* ]]; then
    FORCE_DRIVERS+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm"
fi
if [[ $GPU_TYPE == *"amd"* ]]; then
    FORCE_DRIVERS+=" amdgpu"
fi
if [[ $GPU_TYPE == *"intel"* ]]; then
    FORCE_DRIVERS+=" i915"
fi

if [ -n "$FORCE_DRIVERS" ]; then
    echo "force_drivers+=\"${FORCE_DRIVERS} \"" | sudo tee "$DRACUT_CONF" > /dev/null
else
    sudo rm -f "$DRACUT_CONF"
fi

if [[ -f "$DRACUT_CONF" ]]; then
    sudo dracut --force || true
fi

show_progress 5 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_rpm_lock
install_missing -y --skip-unavailable kernel-devel kernel-devel-matched || true
wait_for_rpm_lock
sudo dnf5 -y copr enable rok/cdemu || true
wait_for_rpm_lock
install_missing -y --skip-unavailable cdemu-daemon cdemu-client gcdemu || true
for pkg in cdemu-daemon cdemu-client; do
    rpm -q "$pkg" &>/dev/null || FAILED_PACKAGES+=("$pkg")
done

sudo systemctl disable --now cdemu-daemon 2>/dev/null || true
sudo systemctl mask cdemu-daemon 2>/dev/null || true
mkdir -p "$HOME/.config/autostart"
for f in /etc/xdg/autostart/gcdemu.desktop /etc/xdg/autostart/cdemu.desktop /usr/share/applications/gcdemu.desktop; do
    if [[ -f "$f" ]]; then
        cp -f "$f" "$HOME/.config/autostart/$(basename "$f")"
        if grep -q '^Hidden=' "$HOME/.config/autostart/$(basename "$f")"; then
            sed -i 's/^Hidden=.*/Hidden=true/' "$HOME/.config/autostart/$(basename "$f")"
        else
            echo "Hidden=true" >> "$HOME/.config/autostart/$(basename "$f")"
        fi
    fi
done
pkill -f gcdemu 2>/dev/null || true

LSFG_TMP="$(mktemp -d)"
LSFG_UA="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
LSFG_HTML="$(curl -fsSL -A "$LSFG_UA" -e "https://builds.lsfg-vk.dev/" "https://builds.lsfg-vk.dev/" 2>/dev/null || true)"
LSFG_LINKS="$( { printf '%s' "$LSFG_HTML" | grep -oiE 'href="[^"]+\.tar\.xz"' | sed -E 's/^href="//I; s/"$//'; } || true )
$( { printf '%s' "$LSFG_HTML" | grep -oiE 'https?://[^"'"'"'<>[:space:]]+\.tar\.xz'; } || true )"
LSFG_URL="$(printf '%s\n' "$LSFG_LINKS" | grep -iE '(^|/)lsfg-vk-[0-9]+(\.[0-9]+)*\.tar\.xz$' | sort -Vu | tail -n1 || true)"
if [[ -z "$LSFG_URL" ]]; then
    LSFG_URL="$(printf '%s\n' "$LSFG_LINKS" | head -n1 || true)"
fi
if [[ -n "$LSFG_URL" && "$LSFG_URL" != http* ]]; then
    case "$LSFG_URL" in
        /*) LSFG_URL="https://builds.lsfg-vk.dev${LSFG_URL}" ;;
        *)  LSFG_URL="https://builds.lsfg-vk.dev/${LSFG_URL}" ;;
    esac
fi
if [[ -n "$LSFG_URL" ]] && curl -fsSL -A "$LSFG_UA" -o "$LSFG_TMP/lsfg-vk.tar.xz" "$LSFG_URL" 2>/dev/null && tar -tf "$LSFG_TMP/lsfg-vk.tar.xz" &>/dev/null && mkdir -p "$HOME/.local" && tar -xf "$LSFG_TMP/lsfg-vk.tar.xz" -C "$HOME/.local"; then
    :
else
    log_warn "lsfg-vk: nie udało się pobrać gotowej paczki, pomijam" \
             "lsfg-vk: failed to download prebuilt package, skipping"
fi
rm -rf "$LSFG_TMP"

show_progress 6 $TOTAL_STEPS "$MSG_PHASE_2"

mkdir -p "$RPM_DIR"
download_rpm() { wget -q --timeout=30 -O "$3" "$2" || rm -f "$3"; }

wait_for_rpm_lock
if rpm -q discord &>/dev/null; then
    :
elif sudo dnf5 repolist 2>/dev/null | grep -iq "rpmfusion-nonfree"; then
    sudo dnf5 install -y discord || true
else
    dest="/tmp/discord.rpm"
    if wget -q --user-agent="Mozilla/5.0" "https://discord.com/api/download?platform=linux&format=rpm" -O "$dest"; then
        if file "$dest" | grep -q "RPM"; then
            wait_for_rpm_lock
            sudo dnf5 install -y --no-gpgchecks "$dest" || true
            rm -f "$dest"
        fi
    fi
fi

OPENCODE_URL=""
rpm -q opencode-desktop &>/dev/null || OPENCODE_URL=$(curl -sfL https://api.github.com/repos/anomalyco/opencode/releases/latest | grep "browser_download_url.*opencode-desktop-linux-x86_64\.rpm" | cut -d '"' -f 4 || true)
[[ -n "$OPENCODE_URL" ]] && download_rpm "opencode-desktop" "$OPENCODE_URL" "$RPM_DIR/opencode-desktop.rpm"

wait_for_rpm_lock
if ! rpm -q faugus-launcher &>/dev/null; then
    sudo dnf5 -y copr enable faugus/faugus-launcher && sudo dnf5 --refresh -y install faugus-launcher || true
fi

shopt -s nullglob
RPM_FILES=("$RPM_DIR"/*.rpm)
if [[ ${#RPM_FILES[@]} -gt 0 ]]; then
    wait_for_rpm_lock
    sudo dnf5 install -y --no-gpgchecks "${RPM_FILES[@]}" || true
fi
shopt -u nullglob
rm -rf "$RPM_DIR"

APPLICATIONS_DIR="$HOME/.local/share/applications"
for shortcut in \
    "io.github.eugeniosegala.mako.desktop" \
    "io.github.eugeniosegala.mako.uninstaller.desktop"; do
    rm -f "$APPLICATIONS_DIR/$shortcut"
done

show_progress 7 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_rpm_lock
install_missing -y --skip-unavailable virt-manager qemu-kvm qemu-img libvirt libvirt-daemon-kvm || true

if command -v dconf &>/dev/null; then
    dconf load /org/virt-manager/virt-manager/ <<'DCONFEOF'
[/]
manager-window-height=297
manager-window-width=478
xmleditor-enabled=true

[confirm]
delete-storage=false
forcepoweroff=false

[connections]
autoconnect=['qemu:///system']
uris=['qemu:///system']

[conns/qemu:system]
window-size=(800, 600)

[details]
show-toolbar=true

[new-vm]
cpu-default='host-passthrough'
firmware='uefi'
graphics-type='spice'
storage-format='raw'

[stats]
enable-disk-poll=true
enable-memory-poll=true
enable-net-poll=true

[vmlist-fields]
disk-usage=false
network-traffic=false

autoconnect=1
vm-window-size=(1280, 842)
DCONFEOF
fi

for svc in libvirtd virtqemud; do
    if systemctl list-unit-files "$svc.service" &>/dev/null 2>&1 && systemctl list-unit-files "$svc.service" | grep -q "$svc"; then
        sudo systemctl enable --now "$svc.service" || true
        break
    fi
done

LIBVIRT_NET="192.168.122.0/24"
if ip -4 -o addr show 2>/dev/null | awk '$2 != "virbr0" && $4 ~ /^192\.168\.122\./ {found=1} END {exit !found}'; then
    LIBVIRT_NET="192.168.150.0/24"
fi

LIBVIRT_NET_XML="$(mktemp)"
if sudo virsh net-info default &>/dev/null; then
    sudo virsh net-dumpxml default --inactive > "$LIBVIRT_NET_XML"
else
    cp /usr/share/libvirt/networks/default.xml "$LIBVIRT_NET_XML"
fi
if [[ "$LIBVIRT_NET" == "192.168.150.0/24" ]] && grep -q '192\.168\.122\.' "$LIBVIRT_NET_XML"; then
    sed -i 's/192\.168\.122\./192.168.150./g' "$LIBVIRT_NET_XML"
    sudo virsh net-destroy default 2>/dev/null || true
    sudo virsh net-undefine default 2>/dev/null || true
fi
if ! sudo virsh net-info default &>/dev/null; then
    sudo virsh net-define "$LIBVIRT_NET_XML" || true
fi
rm -f "$LIBVIRT_NET_XML"
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default || true

if command -v firewall-cmd &>/dev/null; then
    sudo systemctl enable --now firewalld || true
    sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0 2>/dev/null || true
    sudo firewall-cmd --permanent --zone=trusted --add-source="$LIBVIRT_NET" 2>/dev/null || true
    if rpm -q openssh-server &>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        sudo firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
    fi
    sudo firewall-cmd --reload 2>/dev/null || true
fi

for grp in libvirt kvm; do
    getent group "$grp" &>/dev/null && sudo usermod -aG "$grp" "$CURRENT_USER" || true
done

show_progress 8 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_rpm_lock
install_missing -y flatpak || true

if ! flatpak remote-list 2>/dev/null | grep -q "^flathub"; then
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi

sudo flatpak update --appstream || true
flatpak info com.github.tchx84.Flatseal &>/dev/null || sudo flatpak install -y flathub com.github.tchx84.Flatseal || true
flatpak info it.mijorus.gearlever &>/dev/null || sudo flatpak install -y flathub it.mijorus.gearlever || true

# ==========================================================
#  ETAP 3/4: OPTYMALIZACJA
# ==========================================================
show_progress 9 $TOTAL_STEPS "$MSG_PHASE_3"

sudo systemctl unmask packagekit.service packagekit-offline-update.service dnf-makecache.timer dnf-makecache.service dnf5-makecache.timer dnf5-makecache.service 2>/dev/null || true
restore_packagekit
sudo systemctl enable fstrim.timer || true
sudo journalctl --vacuum-time=2d || true

show_progress 10 $TOTAL_STEPS "$MSG_PHASE_3"

sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub || true
grep -q 'mitigations=off' /etc/default/grub || sudo sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mitigations=off"/' /etc/default/grub || true
grep -q 'split_lock_detect=off' /etc/default/grub || sudo sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 split_lock_detect=off"/' /etc/default/grub || true
sudo grubby --update-kernel=ALL --args="mitigations=off split_lock_detect=off" 2>/dev/null || true
sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

show_progress 11 $TOTAL_STEPS "$MSG_PHASE_3"

if command -v zsh &>/dev/null; then
    sudo chsh -s "$(command -v zsh)" "$CURRENT_USER" || true

    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
    fi

    P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
    if [[ ! -d "$P10K_DIR" ]]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR" || true
    fi

    ZSHRC="$HOME/.zshrc"
    if [[ -f "$ZSHRC" ]]; then
        sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$ZSHRC" || true
        sed -i 's/^plugins=(.*/plugins=(git sudo systemd fedora dnf)/' "$ZSHRC" || true
        SHELL_LOCALE="${LANG:-${LC_ALL:-${LC_MESSAGES:-en_US.UTF-8}}}"
        if command -v locale &>/dev/null; then
            AVAILABLE_LOCALES="$(locale -a 2>/dev/null)"
            if ! echo "$AVAILABLE_LOCALES" | grep -qiF "$SHELL_LOCALE" && ! echo "$AVAILABLE_LOCALES" | grep -qiF "$(echo "$SHELL_LOCALE" | sed 's/UTF-8/utf8/')"; then
                SHELL_LOCALE="en_US.UTF-8"
            fi
        fi
        grep -q "^export LC_ALL=" "$ZSHRC" || echo "export LC_ALL=${SHELL_LOCALE}" >> "$ZSHRC"
        grep -q "^fastfetch"         "$ZSHRC" || echo "fastfetch"                  >> "$ZSHRC"
        grep -q "zsh-syntax-highlighting.zsh" "$ZSHRC" || echo "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> "$ZSHRC"
        grep -q "zsh-autosuggestions.zsh"     "$ZSHRC" || echo "source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"         >> "$ZSHRC"
    fi
fi


# =============================================================
#  ETAP 4/4: CZYSZCZENIE
# =============================================================
show_progress 12 $TOTAL_STEPS "$MSG_PHASE_4"
printf '\n\n' >&3

if [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
    log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}" "Failed to install: ${FAILED_PACKAGES[*]}"
fi

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}[OK] KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}[OK] CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
fi

# ==========================================================
#  RESTART SYSTEMU
# ==========================================================
if [[ "$SCRIPT_LANG" == "pl" ]]; then
    RESTART_PROMPT="Czy chcesz teraz zrestartować system? [T/N]: "
else
    RESTART_PROMPT="Do you want to restart the system now? [Y/N]: "
fi
echo -en "${INFO}==> ${RESTART_PROMPT}${NC}" >&3
read -r RESTART_CHOICE < /dev/tty
case "$RESTART_CHOICE" in
    [YyTt]*)
        DO_REBOOT=1
        ;;
esac
exit 0
