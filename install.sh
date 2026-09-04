#!/bin/bash
# ==========================================================
# KOMPLEKSOWY SKRYPT KONFIGURACYJNY SYSTEMU (FEDORA)
# ==========================================================

set -euo pipefail
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
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}✖ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
        else
            echo -e "${ERR}✖ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
        fi
    fi
    rm -f "$TMP_LOG"
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${SUCCESS}✔ $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${ERR}✘ ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; echo -e "${WARN}⚠ WARN: $m${NC}"; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

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

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    MSG_PHASE_1="[1/3] Konfiguracja i optymalizacja systemu..."
    MSG_PHASE_2="[2/3] Instalacja pakietów systemowych, Flathub i paczek RPM..."
    MSG_PHASE_3="[3/3] Konfiguracja usług, bootloadera i środowiska..."
else
    MSG_PHASE_1="[1/3] System configuration and optimization..."
    MSG_PHASE_2="[2/3] Installing system, Flathub, and RPM packages..."
    MSG_PHASE_3="[3/3] Configuring services, bootloader, and environment..."
fi

TOTAL_STEPS=12
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CURRENT_USER=$(whoami)
RPM_DIR="/tmp/rpms_$$"

if [[ "$EUID" -eq 0 ]]; then
    echo -e "${ERR}✖ Nie uruchamiaj skryptu jako root. Użyj zwykłego użytkownika z sudo.${NC}" >&3
    exit 1
fi

printf '\033[?7h\n' >&3

RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1 || sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

sudo -v

if [[ "$USE_RUN0" -eq 1 ]]; then
    printf 'polkit._run0_nopasswd.push("%s");\n' "$CURRENT_USER" | sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null
    sudo systemctl try-restart polkit 2>/dev/null || true
else
    SUDOERS_TMP="$(mktemp)"
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    chmod 0440 "$SUDOERS_TMP"
    if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null; then
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
    else
        rm -f "$SUDOERS_TMP"
        echo -e "${ERR}✖ Nieprawidłowa składnia pliku sudoers – przerywam.${NC}" >&3
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
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

# ==========================================================
#  ETAP 1/3: KONFIGURACJA I OPTYMALIZACJA SYSTEMU
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

sudo systemctl stop packagekit.service dnf-makecache.timer dnf-makecache.service dnf5-makecache.timer dnf5-makecache.service 2>/dev/null || true
sudo systemctl mask packagekit.service dnf-makecache.timer dnf-makecache.service dnf5-makecache.timer dnf5-makecache.service 2>/dev/null || true
sudo killall -9 packagekitd dnf dnf5 rpm 2>/dev/null || true

for DNF_CONF in /etc/dnf/dnf.conf /etc/dnf/dnf5.conf; do
    if [[ -f "$DNF_CONF" ]]; then
        sudo sed -i '/^fastestmirror=/d; /^retries=/d; /^timeout=/d; /^max_parallel_downloads=/d; /^ip_resolve=/d' "$DNF_CONF"
        echo -e "fastestmirror=False\nmax_parallel_downloads=10\nretries=10\ntimeout=120\nip_resolve=4" | sudo tee -a "$DNF_CONF" > /dev/null
    fi
done

wait_for_rpm_lock
for pkg in wget curl pciutils dconf; do
    sudo dnf5 install -y "$pkg" || true
done

show_progress 2 $TOTAL_STEPS "$MSG_PHASE_1"

FEDORA_VER=$(rpm -E %fedora)
wait_for_rpm_lock
sudo dnf5 install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" || true

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
    sudo dnf5 install -y "$pkg" || true
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

sudo dnf5 config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo || true

show_progress 3 $TOTAL_STEPS "$MSG_PHASE_1"

wait_for_rpm_lock
sudo dnf5 install -y @development-tools @c-development gcc gcc-c++ make || true

TO_REMOVE=(
    nano konqueror plasma-browser-integration plasma-vault krdp krfb
    plasma-thunderbolt kontact kmail kontrast plasma-welcome showtime elisa
    evolution evolution-common evolution-plugins evolution-ews rhythmbox dragon
    kaddressbook kdepim-runtime akonadi-server akregator korganizer parole
    epiphany decibels gnome-calendar gnome-clocks gnome-user-docs showtime
    gnome-contacts gnome-maps gnome-weather yelp kwalletmanager gnome-music
)
wait_for_rpm_lock
for pkg in "${TO_REMOVE[@]}"; do
    sudo dnf5 remove -y "$pkg" 2>/dev/null || true
done
sudo dnf5 autoremove -y || true

rm -rf ~/.local/share/akonadi ~/.local/share/kmail2 ~/.local/share/local-mail ~/.local/share/contacts ~/.local/share/korganizer ~/.local/share/akregator ~/.local/share/kontact ~/.local/share/konqueror
rm -rf ~/.config/akonadi* ~/.config/kmail* ~/.config/kontact* ~/.config/korganizer* ~/.config/kaddressbook* ~/.config/akregator* ~/.config/emailidentities ~/.config/mailtransports
rm -rf ~/.cache/akonadi* ~/.cache/kmail* ~/.cache/kontact* ~/.cache/korganizer* ~/.cache/kaddressbook* ~/.cache/akregator* ~/.cache/konqueror*
rm -rf ~/.local/share/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,evolution}
rm -rf ~/.config/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,evolution}
rm -rf ~/.cache/{epiphany,decibels,gnome-user-docs,gnome-contacts,gnome-maps,gnome-weather,evolution}

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
#  ETAP 2/3: INSTALACJA PAKIETÓW I OPROGRAMOWANIA
# ==========================================================
show_progress 4 $TOTAL_STEPS "$MSG_PHASE_2"

PACKAGES=(
    google-chrome-stable brave-origin 
    dconf-editor hunspell-pl fastfetch unrar git mc exfatprogs ntfs-3g vim
    os-prober android-tools fsarchiver inxi pv rsync python3-defusedxml
    python3-packaging python3-pip pipx 7zip zenity innoextract makeself
    bleachbit timeshift cdemu-daemon cdemu-client vlc vlc-plugin-access-extra
    audacity gimp gmic mixxx kdenlive soundconverter handbrake-gui
    telegram-desktop qbittorrent thunderbird qmmp qmmp-plugin-pack
    wine winetricks
    gamemode vulkan-tools gamescope mangohud goverlay
    cmake meson ninja-build python3-tqdm just
    gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugins-ugly
    bluez-tools zsh zsh-syntax-highlighting zsh-autosuggestions
    libayatana-appindicator
)

wait_for_rpm_lock
sudo dnf5 install -y --skip-unavailable "${PACKAGES[@]}" || true

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

show_progress 5 $TOTAL_STEPS "$MSG_PHASE_2"

PACKAGES_32=(
    glibc.i686 libstdc++.i686 libgcc.i686 vulkan-loader.i686
    wine.i686 alsa-lib.i686 pipewire-alsa.i686 pipewire-libs.i686
    pulseaudio-libs.i686 openal-soft.i686 mangohud.i686 gamemode.i686
    openssl-libs.i686 nss.i686 nspr.i686 libXcomposite.i686 libXcursor.i686
    libXdamage.i686 libXext.i686 libXfixes.i686 libXi.i686 libXrandr.i686
    libXrender.i686 libXtst.i686 libxkbcommon.i686
)

GPU_INFO=$(lspci -nn | grep -iE "VGA|3D|Display" || true)
DRACUT_CONF="/etc/dracut.conf.d/90-gpu.conf"
MESA_32_PKGS=(mesa-dri-drivers.i686 mesa-vulkan-drivers.i686 mesa-libGL.i686)

GPU_HAS_NVIDIA=0
GPU_HAS_AMD=0
GPU_HAS_INTEL=0
echo "$GPU_INFO" | grep -iq "NVIDIA" && GPU_HAS_NVIDIA=1
echo "$GPU_INFO" | grep -iqE "AMD|Radeon" && GPU_HAS_AMD=1
echo "$GPU_INFO" | grep -iq "Intel" && GPU_HAS_INTEL=1

GPU_VENDOR_COUNT=$(( GPU_HAS_NVIDIA + GPU_HAS_AMD + GPU_HAS_INTEL ))
FORCE_DRIVERS=""

if (( GPU_VENDOR_COUNT >= 2 )); then
    log_info "Wykryto hybrydowy układ graficzny (więcej niż jedno GPU)." "Detected a hybrid GPU setup (more than one GPU)."
fi

if (( GPU_HAS_NVIDIA )); then
    PACKAGES_32+=(xorg-x11-drv-nvidia-libs.i686 xorg-x11-drv-nvidia-cuda-libs.i686)
    FORCE_DRIVERS+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm"
fi
if (( GPU_HAS_AMD )); then
    PACKAGES_32+=("${MESA_32_PKGS[@]}")
    FORCE_DRIVERS+=" amdgpu"
fi
if (( GPU_HAS_INTEL )); then
    PACKAGES_32+=("${MESA_32_PKGS[@]}")
    FORCE_DRIVERS+=" i915"
fi

if (( GPU_VENDOR_COUNT > 0 )); then
    readarray -t PACKAGES_32 < <(printf '%s\n' "${PACKAGES_32[@]}" | awk '!seen[$0]++')
    echo "force_drivers+=\"${FORCE_DRIVERS} \"" | sudo tee "$DRACUT_CONF" > /dev/null
else
    PACKAGES_32+=("${MESA_32_PKGS[@]}")
    sudo rm -f "$DRACUT_CONF"
fi

wait_for_rpm_lock
sudo dnf5 install -y --skip-unavailable "${PACKAGES_32[@]}" || true

if [[ -f "$DRACUT_CONF" ]]; then
    sudo dracut --force || true
fi

show_progress 6 $TOTAL_STEPS "$MSG_PHASE_2"

mkdir -p "$RPM_DIR"
download_rpm() { wget -q --timeout=30 -O "$3" "$2" || rm -f "$3"; }

wait_for_rpm_lock
if sudo dnf5 repolist 2>/dev/null | grep -iq "rpmfusion-nonfree"; then
    sudo dnf5 install -y discord || true
else
    dest="/tmp/discord.rpm"
    if wget -q --user-agent="Mozilla/5.0" "https://discord.com/api/download?platform=linux&format=rpm" -O "$dest"; then
        if file "$dest" | grep -q "RPM"; then
            sudo dnf5 install -y "$dest" || true
            rm -f "$dest"
        fi
    fi
fi

LSFG_URL=$(curl -sf https://api.github.com/repos/YuriSizov/ls-fg/releases/latest | grep "browser_download_url.*ls-fg_.*rpm" | cut -d '"' -f 4 || true)
[[ -n "$LSFG_URL" ]] && download_rpm "ls-fg" "$LSFG_URL" "$RPM_DIR/lsfg.rpm"

LSFG_VK_URL=$(curl -sf https://api.github.com/repos/YuriSizov/ls-fg-vk/releases/latest | grep "browser_download_url.*rpm" | cut -d '"' -f 4 || true)
[[ -n "$LSFG_VK_URL" ]] && download_rpm "ls-fg-vk" "$LSFG_VK_URL" "$RPM_DIR/lsfg-vk.rpm"

wait_for_rpm_lock
sudo dnf5 -y copr enable faugus/faugus-launcher && sudo dnf5 --refresh -y install faugus-launcher || true

shopt -s nullglob
RPM_FILES=("$RPM_DIR"/*.rpm)
if [[ ${#RPM_FILES[@]} -gt 0 ]]; then
    wait_for_rpm_lock
    sudo dnf5 install -y "${RPM_FILES[@]}" || true
fi
shopt -u nullglob
rm -rf "$RPM_DIR"

show_progress 7 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_rpm_lock
sudo dnf5 install -y --skip-unavailable virt-manager qemu-kvm qemu-img libvirt libvirt-daemon-kvm edk2-ovmf dnsmasq || true

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

[vms/2a91721fef6c4249997ea19b01801825]
autoconnect=1
vm-window-size=(1280, 842)
DCONFEOF

for svc in libvirtd virtqemud; do
    if systemctl list-unit-files "$svc.service" &>/dev/null 2>&1 && systemctl list-unit-files "$svc.service" | grep -q "$svc"; then
        sudo systemctl enable --now "$svc.service" || true
        break
    fi
done

if ! sudo virsh net-info default &>/dev/null; then
    sudo virsh net-define /usr/share/libvirt/networks/default.xml || true
fi
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default || true

if command -v firewall-cmd &>/dev/null; then
    sudo systemctl enable --now firewalld || true
    sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0 2>/dev/null || true
    sudo firewall-cmd --permanent --add-source=192.168.122.0/24 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
fi

for grp in libvirt kvm; do
    getent group "$grp" &>/dev/null && sudo usermod -aG "$grp" "$CURRENT_USER" || true
done

show_progress 8 $TOTAL_STEPS "$MSG_PHASE_2"

wait_for_rpm_lock
sudo dnf5 install -y flatpak || true

if ! flatpak remote-list 2>/dev/null | grep -q "^flathub"; then
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi

sudo flatpak update --appstream || true
sudo flatpak install -y flathub com.github.tchx84.Flatseal || true
sudo flatpak install -y flathub it.mijorus.gearlever || true

# ==========================================================
#  ETAP 3/3: KONFIGURACJA USŁUG, BOOTLOADERA I ŚRODOWISKA
# ==========================================================
show_progress 9 $TOTAL_STEPS "$MSG_PHASE_3"

sudo systemctl unmask packagekit.service dnf-makecache.timer dnf-makecache.service dnf5-makecache.timer dnf5-makecache.service 2>/dev/null || true
sudo systemctl enable fstrim.timer || true
sudo journalctl --vacuum-time=2d || true

show_progress 10 $TOTAL_STEPS "$MSG_PHASE_3"

sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub || true
sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

show_progress 11 $TOTAL_STEPS "$MSG_PHASE_3"

sudo mkdir -p /etc/NetworkManager/conf.d
echo -e "[main]\ndns=default\nrc-manager=symlink" | sudo tee /etc/NetworkManager/conf.d/dns.conf > /dev/null
echo -e "[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.1,1.0.0.1,2606:4700:4700::1112,2606:4700:4700::1002" | sudo tee /etc/NetworkManager/conf.d/global-dns.conf > /dev/null

ACTIVE_CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -v "^lo" | head -n 1 | cut -d: -f1 || true)
if [[ -n "$ACTIVE_CONN" ]]; then
    sudo nmcli connection modify "$ACTIVE_CONN" ipv4.dns "1.1.1.1,1.0.0.1" ipv6.dns "2606:4700:4700::1112,2606:4700:4700::1002"
    sudo nmcli connection up "$ACTIVE_CONN" || true
fi

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

if [[ "$USE_RUN0" -eq 1 ]]; then
    sudo rm -f "$RUN0_NOPASSWD_FILE"
    sudo systemctl try-restart polkit 2>/dev/null || true
else
    sudo rm -f /etc/sudoers.d/99-temp-installer
fi

show_progress 12 $TOTAL_STEPS "$MSG_PHASE_3"
echo -e "\n" >&3

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}✔ KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}✔ CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
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
        systemctl reboot
        ;;
    *)
        exit 0
        ;;
esac
