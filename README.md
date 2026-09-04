# 🎩 Fedora Post-Install Setup Script

A comprehensive, automated Bash post-installation script for **Fedora**. It configures `dnf5` and third-party repositories (RPM Fusion, Google Chrome, Brave), removes unwanted default apps, detects your GPU and installs matching `.i686` driver libraries, installs a large curated set of system/multimedia/gaming packages plus Flatpak and standalone `.rpm` packages, configures virtualization (libvirt/QEMU) and the firewall, configures the GRUB boot splash, and sets up Zsh with Oh My Zsh and Powerlevel10k.

The script auto-detects the system language (Polish/English) from the `LANG`/`LC_ALL` locale and prints all status messages accordingly.

---

## 🚀 Script Features

- **Temporary Passwordless Sudo**: Requests the admin password once at the start, then configures a temporary `NOPASSWD` rule (via `/etc/sudoers.d/`, or a `polkit`/`run0` rule on systems without `visudo`) so the rest of the script can run unattended. The rule is automatically removed at the end.
- **RPM/DNF Lock Handling (`wait_for_rpm_lock`)**: Waits for any running `dnf`/`dnf5`/`rpm`/`packagekitd` process to finish before each package operation; after ~2 minutes of waiting it force-stops PackageKit/DNF services, kills the processes, and removes stale RPM lock files so the script never gets stuck.
- **DNF Tuning & Background Services**: Stops and masks PackageKit and the `dnf(5)-makecache` timers/services during installation (unmasked again at the end) to avoid interference, and tunes `dnf.conf`/`dnf5.conf` (`fastestmirror=False`, `max_parallel_downloads=10`, `retries=10`, `timeout=120`, `ip_resolve=4`).
- **Third-Party Repository Setup**: Enables **RPM Fusion** (free + nonfree, matched to the detected Fedora version), adds the official **Google Chrome** repo (cleaning up any stale Google GPG keys first), and adds the official **Brave Browser** repo via `dnf5 config-manager addrepo` (with a manual GPG-key import fallback).
- **Development Tools & Bloatware Removal**: Installs the `@development-tools`/`@c-development` groups plus `gcc`/`gcc-c++`/`make`, then removes a long list of default KDE/GNOME apps (`konqueror`, `kontact`, `kmail`, `korganizer`, `akonadi-server`, `evolution`, `rhythmbox`, `gnome-maps`, `yelp`, etc.) along with their leftover config/cache directories, and disables the KWallet secret service if KDE Plasma is present.
- **Package Installation**: Installs a large curated `PACKAGES` set covering browsers (Chrome, Brave), office/media apps (Thunderbird, GIMP, Kdenlive, Audacity, VLC...), dev tools (`cmake`, `meson`, `ninja-build`, `just`...), and the gaming/Wine stack (`wine`, `winetricks`, `gamemode`, `gamescope`, `mangohud`, `goverlay`, `vulkan-tools`).
- **GPU Detection & 32-bit Driver Setup**: Detects NVIDIA/AMD/Intel GPUs (and hybrid setups) via `lspci`, installs a base set of `.i686` compatibility libraries (glibc, Wine, audio, X11) plus vendor-specific packages (NVIDIA driver/CUDA libs, or Mesa/Vulkan for AMD/Intel), configures `dracut` to force-load the right kernel modules, and rebuilds the initramfs with `dracut --force`.
- **Standalone `.rpm` Packages**: Installs Discord from RPM Fusion nonfree if available, otherwise downloads it directly from Discord's official endpoint; downloads `ls-fg`/`ls-fg-vk` via the GitHub Releases API; installs Faugus Launcher via its official Copr repository (`faugus/faugus-launcher`).
- **Virtualization & Firewall**: Installs `virt-manager`, `qemu-kvm`, `libvirt`, `edk2-ovmf`, and related tools; imports default `virt-manager` GUI preferences via `dconf load`; enables `libvirtd`/`virtqemud`; defines/starts/autostarts the default libvirt NAT network; enables **firewalld** and adds the `libvirt` zone interface (`virbr0`) plus the libvirt subnet as a trusted source; adds the user to the `libvirt`/`kvm` groups.
- **Flatpak**: Installs `flatpak`, adds the Flathub remote if missing, and installs Flatseal + Gear Lever.
- **Boot Splash (GRUB)**: Sets `GRUB_TIMEOUT=0` and regenerates the GRUB config with `grub2-mkconfig`.
- **System Tuning & DNS**: Re-enables the DNF background services, enables `fstrim.timer`, vacuums the journal to 2 days, and sets Cloudflare (`1.1.1.1`/`1.0.0.1` + IPv6) as the system and NetworkManager DNS, applying it to the active connection.
- **Shell Setup**: If `zsh` is available, sets it as the default shell, installs Oh My Zsh (unattended) and the Powerlevel10k theme, and updates `~/.zshrc` (theme, plugins, locale export, `fastfetch` on login, syntax-highlighting/autosuggestions sourcing).
- **Dotfiles & Config Copy**: Copies an optional `.update.sh` helper script plus `.local`/`.config` directories from the script folder into the user's home directory.
- **Progress Bar & Logging**: Displays a live progress bar across 3 phases / 12 steps. On failure, a detailed log is saved to `~/install_error_<timestamp>.log`.
- **Optional Reboot Prompt**: Asks **"Do you want to restart the system now? [Y/N]"** at the end instead of forcing a reboot.

---

## 🔍 Module Details

### 1. Permissions & Repository Setup
Grants temporary `NOPASSWD` sudo, stops/masks PackageKit and DNF cache services, tunes DNF settings, enables RPM Fusion (free + nonfree) for the detected Fedora version, and adds the Google Chrome and Brave repositories.

### 2. Development Tools & Bloatware Cleanup
Installs the base development toolchain, then removes the predefined list of default KDE/GNOME applications and their leftover config/cache, and disables KWallet if KDE Plasma is present.

### 3. Package & Driver Installation
Installs the curated package set, detects the GPU vendor(s) and installs the matching base + vendor-specific `.i686` compatibility packages, configures `dracut` to force-load the right kernel modules, and rebuilds the initramfs.

### 4. Standalone RPMs, Virtualization & Flatpak
Installs Discord (from RPM Fusion or a direct download fallback), `ls-fg`/`ls-fg-vk` (via GitHub Releases), and Faugus Launcher (via Copr); sets up `virt-manager`/QEMU/libvirt with a default NAT network, imported GUI preferences, and firewalld rules; installs Flatpak/Flathub with Flatseal and Gear Lever.

### 5. Boot Splash & System Tuning
Sets a zero-second GRUB timeout and regenerates the GRUB config, re-enables DNF background services, trims the journal, and configures Cloudflare DNS.

### 6. Shell & Finalization
Sets up Zsh + Oh My Zsh + Powerlevel10k (if `zsh` is present), removes the temporary sudo/polkit rule, and prompts the user to reboot immediately or exit without rebooting.

---

🚀 How to Run

1. Clone your repository
```bash
git clone https://github.com/syscore88/fedora-config.git
```

2. Enter the downloaded folder
```bash
cd fedora-config
```

3. Make the install.sh script executable
```bash
chmod +x install.sh
```

4. Run the script
⚠️ **IMPORTANT:** Run the script as a **regular user** (NOT as root/sudo). The script will ask for the administrator password at the start to configure      temporary elevated privileges.
```bash
./install.sh
```
---

### ☕ Support the Project

If you find this tool helpful and it saved you some time, consider buying me a coffee to support further development! 

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/bartekszczecinski)

---

If you find this project useful, leave a star! ⭐

---

## ⚠️ Requirements & Notes

- A base **Fedora** installation with `dnf5` and an internet connection (packages come from the official repos, RPM Fusion, Google/Brave repos, a Copr repo, Flathub, and GitHub releases).
- `sudo` access for the current user.
- The following optional files, placed alongside `install.sh`, are picked up automatically if present: `.update.sh`, `.local/`, `.config/`.
- The script **installs a large number of packages** (development, multimedia, gaming, Wine, and full KVM/QEMU virtualization) and **enables/configures firewalld** — review the `PACKAGES` array and firewall rules before running if that doesn't match your needs.
- Boot splash configuration assumes **GRUB** (`grub2-mkconfig`) is the active bootloader; other bootloaders are not handled by this script.
- On failure, check the generated `install_error_<timestamp>.log` file in your home directory for details.
