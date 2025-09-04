#!/usr/bin/env bash
#
# Arch Guided TUI Installer (finished)
# - Run from official Arch ISO (UEFI or BIOS)
# - Uses dialog for TUI
# - Designed for beginners but keeps sensible defaults & safety
#
# USAGE:
# 1) Boot Arch ISO (UEFI or BIOS)
# 2) Connect to internet (ethernet auto, or use iwctl)
# 3) curl -O https://raw.githubusercontent.com/Mansminus/CustomArchInstall/main/install.sh
# 4) chmod +x install.sh && sudo ./install.sh
#
set -euo pipefail
IFS=$'\n\t'

LOG_LIVE="/tmp/arch-installer.log"
# Note: We'll log important actions manually to avoid interfering with dialog TUI

die(){ echo "ERROR: $*" >&2; echo "ERROR: $*" >> "$LOG_LIVE"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
log_action(){ echo "$(date): $*" >> "$LOG_LIVE"; }

# ensure root
[ "$(id -u)" -eq 0 ] || die "Run this script as root from the Arch live environment."

# install dialog if missing
if ! have dialog; then
  echo "Installing dialog for TUI..."
  pacman -Sy --noconfirm --needed dialog || die "Failed to install dialog; ensure internet connection."
fi

# Helper: dialog wrappers
DIALOG_OK=0
dialog_input() { dialog --clear --inputbox "$1" 10 60 "$2" 3>&1 1>&2 2>&3; }
dialog_menu() { dialog --clear --menu "$1" 20 72 16 "${@:2}" 3>&1 1>&2 2>&3; }
dialog_yesno() { dialog --clear --yesno "$1" 10 60; return $?; }
dialog_msg() { dialog --clear --msgbox "$1" 12 70; }
dialog_textbox() { dialog --clear --textbox "$1" 22 76; }

# Ensure target disk is not busy before destructive operations
ensure_disk_not_busy() {
  local disk="$1"
  # Unmount target root if mounted
  umount -R /mnt 2>/dev/null || true
  # Unmount any mountpoints belonging to this disk's partitions
  while read -r name mnt; do
    if [ -n "$mnt" ]; then
      umount -lf "$mnt" 2>/dev/null || true
    fi
  done < <(lsblk -nr -o NAME,MOUNTPOINT "$disk" | awk '$2!=""{print $1" "$2}')
  # Turn off all swap (best-effort)
  swapoff -a 2>/dev/null || true
  # Close dm-crypt mappings on this disk
  while read -r mapper; do
    [ -z "$mapper" ] && continue
    if have cryptsetup; then cryptsetup close "$mapper" 2>/dev/null || true; fi
  done < <(lsblk -nr -o NAME,TYPE "$disk" | awk '$2=="crypt"{print $1}')
  # Deactivate LVM and stop mdraid if available
  if have vgchange; then vgchange -an 2>/dev/null || true; fi
  if have mdadm; then mdadm --stop --scan 2>/dev/null || true; fi
  if have dmsetup; then dmsetup remove -f 2>/dev/null || true; fi
  # Settle and reread partition table
  udevadm settle 2>/dev/null || true
  partprobe "$disk" 2>/dev/null || true
  blockdev --rereadpt "$disk" 2>/dev/null || true
}

# Prechecks
echo "=== Arch Guided Installer ==="
log_action "Arch Guided Installer started"
echo "Logging to $LOG_LIVE"
if ! ping -c1 archlinux.org >/dev/null 2>&1; then
  if dialog --title "Network check" --yesno "No network detected. Do you want to configure Wi-Fi now using iwctl?" 10 60; then
    if ! have iwctl; then
      dialog_msg "iwctl not available in this live environment. Use another way to connect (e.g., connect beforehand) and re-run."
    else
      dialog_msg "Running iwctl interactive. After connecting, re-run this installer."
      iwctl
      if ! ping -c1 archlinux.org >/dev/null 2>&1; then
        die "Still no network. Aborting."
      fi
    fi
  else
    die "Please ensure networking before running installer."
  fi
fi

# detect firmware/UEFI
UEFI=false
[ -d /sys/firmware/efi/efivars ] && UEFI=true

# memory detection
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf("%d\n",$2/1024)}' /proc/meminfo)
LOW_RAM=false
[ "$TOTAL_RAM_MB" -lt 2048 ] && LOW_RAM=true

# Welcome
dialog --title "Welcome" --msgbox "Welcome to the Arch Guided Installer.\n\nThis installer will ask only essential questions and do the rest automatically.\n\nIt will log actions to $LOG_LIVE\n\nPress OK to continue." 14 68

# Optional: Safe install mode for unstable/slow VMs
SAFE_MODE=false
if dialog --title "Safe install mode" --yesno "Enable Safe Install Mode?\n\nRecommended if your VM previously froze.\n- Skips mirror optimization\n- Limits pacman parallel downloads\n- Lowers installer CPU/IO priority\n\nYou can say No if everything runs smoothly." 14 70; then
  SAFE_MODE=true
fi

# Mirror source selection (helps when some mirrors are unstable)
MIRROR_MODE="auto"
MIRROR_CHOICE=$(dialog_menu "Select mirror source (if unsure, choose Auto):" \
  1 "Auto (reflector or default)" \
  2 "Stable (kernel.org + geo)" \
  3 "Region: US (kernel.org + US)" \
  4 "Region: EU (kernel.org + EU)" \
  5 "Region: Asia (kernel.org + Asia)")
case "$MIRROR_CHOICE" in
  2) MIRROR_MODE="stable" ;;
  3) MIRROR_MODE="us" ;;
  4) MIRROR_MODE="eu" ;;
  5) MIRROR_MODE="asia" ;;
  *) MIRROR_MODE="auto" ;;
esac

# LANGUAGE / LOCALE selection
DEFAULT_LOCALE="en_US.UTF-8"
LOCALE_CHOICES=$(grep -E 'UTF-8$' /usr/share/i18n/SUPPORTED 2>/dev/null | awk '{print $1}' | sort | uniq || echo "$DEFAULT_LOCALE")
# build dialog menu list
i=1
MENU_ARGS=()
for loc in $LOCALE_CHOICES; do
  MENU_ARGS+=("$i" "$loc")
  i=$((i+1))
done
LOC_IDX=$(dialog_menu "Choose system locale (UTF-8 preferred):" "${MENU_ARGS[@]}")
SELECTED_LOCALE=$(echo $LOCALE_CHOICES | cut -d' ' -f"$LOC_IDX")
[ -z "$SELECTED_LOCALE" ] && SELECTED_LOCALE="$DEFAULT_LOCALE"

# KEYBOARD layout (auto-detect then allow override)
CURRENT_KBD="us"
if have localectl; then
  TMP=$(localectl status 2>/dev/null || true)
  if echo "$TMP" | grep -qi 'VC Keymap'; then
    CURRENT_KBD=$(echo "$TMP" | awk -F: '/VC Keymap/ {print $2}' | xargs || echo "us")
  fi
fi
# simple common map choices (array-based to avoid IFS issues)
KBD_CHOICES=(us uk de fr es it br ru jp)
MENU_ARGS=()
for idx in "${!KBD_CHOICES[@]}"; do
  num=$((idx+1))
  MENU_ARGS+=("$num" "${KBD_CHOICES[$idx]}")
done
KBD_IDX=$(dialog_menu "Choose keyboard layout (detected: ${CURRENT_KBD}) — you can override:" "${MENU_ARGS[@]}")
# map numeric selection back to value safely
if [ -n "${KBD_IDX}" ] && [ "${KBD_IDX}" -ge 1 ] && [ "${KBD_IDX}" -le ${#KBD_CHOICES[@]} ]; then
  SELECTED_KBD="${KBD_CHOICES[$((KBD_IDX-1))]}"
else
  SELECTED_KBD="${CURRENT_KBD:-us}"
fi
# apply console keymap now
loadkeys "$SELECTED_KBD" || true

# TIMEZONE region/city selection
# Regions
REGIONS=$(find /usr/share/zoneinfo -maxdepth 1 -type d ! -name zoneinfo -printf "%f\n" | sort)
i=1; MENU_ARGS=()
for r in $REGIONS; do MENU_ARGS+=("$i" "$r"); i=$((i+1)); done
REG_IDX=$(dialog_menu "Choose timezone region:" "${MENU_ARGS[@]}")
SELECTED_REGION=$(echo $REGIONS | cut -d' ' -f"$REG_IDX")
# Cities
CITIES=$(find "/usr/share/zoneinfo/$SELECTED_REGION" -maxdepth 1 -type f -printf "%f\n" | sort)
i=1; MENU_ARGS=()
for c in $CITIES; do MENU_ARGS+=("$i" "$c"); i=$((i+1)); done
CIT_IDX=$(dialog_menu "Choose timezone city:" "${MENU_ARGS[@]}")
SELECTED_CITY=$(echo $CITIES | cut -d' ' -f"$CIT_IDX")
TIMEZONE="$SELECTED_REGION/$SELECTED_CITY"

# LANGUAGE PACKING OPTION (translations / docs)
if dialog --title "Language & docs" --yesno "Install only chosen locale and strip other translations/docs/man pages to save disk space? (Recommended for minimal systems)" 12 68; then
  STRIP_LOCALE_YES=true
else
  STRIP_LOCALE_YES=false
fi

# GAMING preference (influences package selection and systemd choice)
GAMING=$(dialog_menu "Will this device be used for gaming (now or maybe later)?" \
  1 "yes (install gaming packages & wide compatibility)" \
  2 "maybe (treat as yes)" \
  3 "no (minimal install)")

case "$GAMING" in
  1|2) GAMING="yes" ;;
  3) GAMING="no" ;;
esac

# WM selection
WMCHOICE=$(dialog_menu "Choose desktop/window manager:" \
  1 "openbox (lightweight floating + panel)" \
  2 "i3 (tiling, keyboard-centric)" \
  3 "dwm (very minimal tiling)" \
  4 "none (server / no desktop)")

case "$WMCHOICE" in
  1) WM="openbox" ;;
  2) WM="i3" ;;
  3) WM="dwm" ;;
  4) WM="none" ;;
esac

# Openbox theme selection (only if Openbox is chosen)
if [ "$WM" = "openbox" ]; then
  OBTHEME=$(dialog_menu "Choose Openbox theme (pairs with Breeze-Dark):" \
    1 "Raven (dark theme with green accents)" \
    2 "Triste (dark theme with red/burgundy accents)")
  
  case "$OBTHEME" in
    1) OPENBOX_THEME="Raven" ;;
    2) OPENBOX_THEME="Triste" ;;
  esac
else
  OPENBOX_THEME=""
fi

# SSH enabling option (disabled by default)
if dialog --title "Remote access" --yesno "Enable SSH server in the installed system? (disabled by default for security)" 10 60; then
  ENABLE_SSH=true
else
  ENABLE_SSH=false
fi

# VM support selection
VM_SUPPORT=$(dialog_menu "Select VM guest tools to install (if any):" \
  1 "none" \
  2 "qemu (qemu-guest-agent)" \
  3 "vbox (VirtualBox guest utils)" \
  4 "vmware (open-vm-tools)")
case "$VM_SUPPORT" in
  1) VM="none" ;;
  2) VM="qemu" ;;
  3) VM="vbox" ;;
  4) VM="vmware" ;;
esac

# USERNAME & PASSWORD
USERNAME=$(dialog_input "Enter username (lowercase):" "user")
[ -z "$USERNAME" ] && die "Username cannot be empty."
# ensure keyboard layout applied before password entry
dialog --title "Keyboard layout" --msgbox "Keyboard layout set to: $SELECTED_KBD\n\nEnter password next. Ensure layout is correct." 10 60
while true; do
  PASS1=$(dialog --insecure --passwordbox "Enter password for $USERNAME:" 10 60 3>&1 1>&2 2>&3)
  PASS2=$(dialog --insecure --passwordbox "Re-enter password for $USERNAME:" 10 60 3>&1 1>&2 2>&3)
  [ "$PASS1" = "$PASS2" ] && break
  dialog_msg "Passwords did not match. Try again."
done

# DISK SELECTION
# show block devices with size & model
DISK_MENU=()
while read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  size=$(echo "$line" | awk '{print $2}')
  model=$(echo "$line" | cut -d' ' -f3-)
  DISK_MENU+=("/dev/$name" "$size $model")
done < <(lsblk -dno NAME,SIZE,MODEL | sed 's/  */ /g')
if [ ${#DISK_MENU[@]} -eq 0 ]; then die "No disks found."; fi
TARGET_DISK=$(dialog_menu "Select the disk to install to (THIS WILL BE ERASED):" "${DISK_MENU[@]}")

dialog_yesno "You selected $TARGET_DISK. THIS WILL ERASE ALL DATA ON THIS DISK.\n\nType YES to confirm destructive action." 12 72
if [ $? -ne 0 ]; then dialog_msg "Aborted by user."; exit 1; fi
# extra confirmation typed check
CONFIRM=$(dialog_input "Type the device path again to confirm (e.g. /dev/sda):" "")
if [ "$CONFIRM" != "$TARGET_DISK" ]; then die "Device confirmation mismatch. Aborting."; fi

# Partitioning logic
log_action "Starting partitioning of $TARGET_DISK (UEFI=$UEFI)"
# ensure disk is not busy, then wipe and create partitions
ensure_disk_not_busy "$TARGET_DISK"
if ! wipefs -a "$TARGET_DISK" 2>/dev/null; then
  # Retry with force after settling
  udevadm settle 2>/dev/null || true
  wipefs -f -a "$TARGET_DISK" 2>/dev/null || true
fi
sgdisk -Z "$TARGET_DISK" >/dev/null 2>&1 || true

if $UEFI; then
  # create EFI (512M) and root partition
  sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "$TARGET_DISK"
  sgdisk -n 2:0:0      -t 2:8300 -c 2:"Linux Root" "$TARGET_DISK"
  partprobe "$TARGET_DISK"
  # determine partition nodes
  EFI_PART=$(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}' | sed -n '1p')
  ROOT_PART=$(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}' | sed -n '2p')
  mkfs.fat -F32 "/dev/$EFI_PART"
  mkfs.ext4 -F "/dev/$ROOT_PART"
  mount "/dev/$ROOT_PART" /mnt
  mkdir -p /mnt/boot
  mount "/dev/$EFI_PART" /mnt/boot
else
  # BIOS: single root partition (optionally can be expanded)
  parted -s "$TARGET_DISK" mklabel msdos
  parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%
  partprobe "$TARGET_DISK"
  ROOT_PART=$(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}' | sed -n '1p')
  mkfs.ext4 -F "/dev/$ROOT_PART"
  mount "/dev/$ROOT_PART" /mnt
fi

# basic mirror refresh and (optionally) optimize mirrors
pacman -Sy --noconfirm --needed archlinux-keyring || true
if [ "$MIRROR_MODE" = "stable" ]; then
  cat > /etc/pacman.d/mirrorlist <<'ML'
Server = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
ML
  pacman -Syy --noconfirm || true
elif [ "$MIRROR_MODE" = "us" ]; then
  cat > /etc/pacman.d/mirrorlist <<'ML'
Server = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
ML
  pacman -Syy --noconfirm || true
elif [ "$MIRROR_MODE" = "eu" ]; then
  cat > /etc/pacman.d/mirrorlist <<'ML'
Server = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch
Server = https://ftp.halifax.rwth-aachen.de/archlinux/$repo/os/$arch
Server = https://mirror.netcologne.de/archlinux/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
ML
  pacman -Syy --noconfirm || true
elif [ "$MIRROR_MODE" = "asia" ]; then
  cat > /etc/pacman.d/mirrorlist <<'ML'
Server = https://mirrors.edge.kernel.org/archlinux/$repo/os/$arch
Server = https://ftp.jaist.ac.jp/pub/Linux/ArchLinux/$repo/os/$arch
Server = https://download.nus.edu.sg/mirror/archlinux/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
ML
  pacman -Syy --noconfirm || true
elif [ "$SAFE_MODE" != "true" ]; then
  # Try to optimize mirrors in the live environment (best-effort)
  if pacman -Sy --noconfirm --needed reflector >/dev/null 2>&1; then
    dialog_msg "Optimizing download mirrors (fastest HTTPS)..."
    timeout 90s reflector --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist >/dev/null 2>&1 || true
  fi
else
  # Limit parallel downloads in safe mode to reduce stress on fragile VMs
  sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 1/' /etc/pacman.conf || true
  sed -i 's/^#\?DisableDownloadTimeout.*/DisableDownloadTimeout = true/' /etc/pacman.conf || true
fi

# base packages to install (minimal but complete)
BASE_PKGS=(base base-devel linux linux-firmware nano sudo reflector)
# networking, audio, xorg baseline
BASE_PKGS+=(networkmanager inetutils network-manager-applet)
BASE_PKGS+=(xorg xorg-xinit)
BASE_PKGS+=(pipewire pipewire-pulse wireplumber pavucontrol)  # audio stack
BASE_PKGS+=(mesa vulkan-icd-loader)  # basic GPU
# utilities (essential only)
BASE_PKGS+=(git wget curl unzip htop)
BASE_PKGS+=(gettext)

# include GRUB and tools
BASE_PKGS+=(grub os-prober efibootmgr)

# Theming and appearance packages (repo-only)
THEME_PKGS=(papirus-icon-theme)
THEME_PKGS+=(breeze breeze-gtk lxappearance qt5ct)
# Essential GUI applications for easy desktop use
THEME_PKGS+=(ristretto vlc evince galculator flameshot)
# System tools with GUI
THEME_PKGS+=(baobab gnome-system-monitor)
# Clean font selection  
THEME_PKGS+=(noto-fonts ttf-dejavu)
THEME_PKGS+=(feh tint2 rofi)
# System tray and desktop utilities (no redundancy)
THEME_PKGS+=(picom volumeicon arandr parcellite)
# Additional utilities for polished experience
THEME_PKGS+=(gvfs gvfs-mtp gvfs-gphoto2 udisks2 xdg-user-dirs)
# User-friendly desktop tools
THEME_PKGS+=(zenity trash-cli gparted i3lock)
# Printer support for complete desktop experience  
THEME_PKGS+=(cups system-config-printer)
# Bluetooth support for modern devices
THEME_PKGS+=(bluez bluez-utils blueman)
# Notification system (essential for modern desktop)
THEME_PKGS+=(dunst libnotify)
# Basic image editing
THEME_PKGS+=(mtpaint)

# optional: small UI tools for openbox/autostart
DESKTOP_PKGS=()
if [ "$WM" = "openbox" ]; then
  DESKTOP_PKGS+=(openbox obconf-qt thunar thunar-archive-plugin)
  DESKTOP_PKGS+=(file-roller geany)
elif [ "$WM" = "i3" ]; then
  DESKTOP_PKGS+=(i3-wm i3status i3lock alacritty thunar thunar-archive-plugin)
  DESKTOP_PKGS+=(file-roller geany)
elif [ "$WM" = "dwm" ]; then
  # Note: dwm needs to be built from source or AUR, using i3 as fallback
  DESKTOP_PKGS+=(i3-wm i3status i3lock st alacritty thunar thunar-archive-plugin)
  DESKTOP_PKGS+=(file-roller geany)
  echo "Note: DWM requires building from source. Installing i3 as fallback."
fi

# Add a graphical display manager when a desktop WM is chosen
if [ "$WM" != "none" ]; then
  DESKTOP_PKGS+=(lightdm lightdm-gtk-greeter)
fi

# browser choice - balance between performance and functionality
if [ "$TOTAL_RAM_MB" -lt 1024 ]; then
  BROWSER_PKG="falkon"       # lightweight Qt browser, still functional
else
  BROWSER_PKG="firefox"      # full-featured, works with everything
fi
DESKTOP_PKGS+=("$BROWSER_PKG")

# Gaming extras - lowered requirement for indie games like Balatro
if [ "$GAMING" = "yes" ] && [ "$TOTAL_RAM_MB" -ge 2048 ]; then
  DESKTOP_PKGS+=(steam lutris mangohud gamemode)
fi

# VM tools
case "$VM" in
  qemu) VM_PKGS=(qemu-guest-agent) ;;
  vbox) VM_PKGS=(virtualbox-guest-utils) ;;
  vmware) VM_PKGS=(open-vm-tools) ;;
  *) VM_PKGS=() ;;
esac

# install base
dialog_msg "Installing the base system now. This can take a while depending on your internet speed.\n\nPlease wait until it completes."
log_action "Installing packages via pacstrap: ${#BASE_PKGS[@]} base + ${#DESKTOP_PKGS[@]} desktop + ${#THEME_PKGS[@]} theme + ${#VM_PKGS[@]} VM packages (safe_mode=${SAFE_MODE})"

# Pre-pacstrap preflight: sync time, ensure no stale pacman lock, check target free space, optionally add temp swap on target
timedatectl set-ntp true 2>/dev/null || true
sleep 1
rm -f /mnt/var/lib/pacman/db.lck 2>/dev/null || true

SWAP_CREATED=false
# Check available space on target root
AVAIL_KB=$(df -Pk /mnt | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 7000000 ]; then
  dialog_msg "Warning: Less than ~7GB free on target. Installation may fail or be cramped."
fi
# Create temporary swapfile on target (not the live ISO) to avoid ISO RAM limits
if [ "$LOW_RAM" = "true" ]; then
  # Decide swap size based on available space
  SWAP_MB=0
  if [ -n "$AVAIL_KB" ]; then
    if [ "$AVAIL_KB" -ge 1500000 ]; then SWAP_MB=1024; # >= ~1.5GB free
    elif [ "$AVAIL_KB" -ge 800000 ]; then SWAP_MB=512;  # >= ~800MB free
    else SWAP_MB=0; fi
  fi
  if [ "$SWAP_MB" -gt 0 ]; then
    log_action "Creating temporary swapfile on target (${SWAP_MB}M) for stability"
    if ! fallocate -l ${SWAP_MB}M /mnt/swapfile 2>/dev/null; then
      dd if=/dev/zero of=/mnt/swapfile bs=1M count=${SWAP_MB} status=none || true
    fi
    if [ -f /mnt/swapfile ]; then
      chmod 600 /mnt/swapfile || true
      mkswap /mnt/swapfile >/dev/null 2>&1 || true
      swapon /mnt/swapfile >/dev/null 2>&1 && SWAP_CREATED=true || true
    fi
  fi
fi

PACSTRAP_LOG="/tmp/pacstrap.log"
set +e
if [ "$SAFE_MODE" = "true" ]; then
  nice -n 10 ionice -c2 -n7 pacstrap -K /mnt "${BASE_PKGS[@]}" "${DESKTOP_PKGS[@]}" "${THEME_PKGS[@]}" "${VM_PKGS[@]}" 2>&1 | tee "$PACSTRAP_LOG"
  PACSTRAP_RC=${PIPESTATUS[0]}
else
  pacstrap -K /mnt "${BASE_PKGS[@]}" "${DESKTOP_PKGS[@]}" "${THEME_PKGS[@]}" "${VM_PKGS[@]}" 2>&1 | tee "$PACSTRAP_LOG"
  PACSTRAP_RC=${PIPESTATUS[0]}
fi
set -e
if [ ${PACSTRAP_RC} -ne 0 ]; then
  log_action "pacstrap failed (code ${PACSTRAP_RC}). Applying fallback mirror and retrying once."
  # Fallback: use geo mirror, minimize parallelism, refresh keyring, then retry once
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
  sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 1/' /etc/pacman.conf || true
  pacman -Syy --noconfirm archlinux-keyring || true
  dialog_msg "First attempt failed. Switching to a stable mirror and retrying installation once...\n\nSee $PACSTRAP_LOG for details (last errors will be shown if it fails again)."
  set +e
  if [ "$SAFE_MODE" = "true" ]; then
    nice -n 10 ionice -c2 -n7 pacstrap -K /mnt "${BASE_PKGS[@]}" "${DESKTOP_PKGS[@]}" "${THEME_PKGS[@]}" "${VM_PKGS[@]}" 2>&1 | tee "$PACSTRAP_LOG"
    PACSTRAP_RC=${PIPESTATUS[0]}
  else
    pacstrap -K /mnt "${BASE_PKGS[@]}" "${DESKTOP_PKGS[@]}" "${THEME_PKGS[@]}" "${VM_PKGS[@]}" 2>&1 | tee "$PACSTRAP_LOG"
    PACSTRAP_RC=${PIPESTATUS[0]}
  fi
  set -e
  if [ ${PACSTRAP_RC} -ne 0 ]; then
    # Show the last 50 lines of pacstrap log to help diagnose
    tail -n 50 "$PACSTRAP_LOG" >/tmp/pacstrap_tail.txt 2>/dev/null || true
    if [ -s /tmp/pacstrap_tail.txt ]; then
      dialog --title "pacstrap error (last 50 lines)" --textbox /tmp/pacstrap_tail.txt 22 90
    fi
    dialog_msg "The base installation step failed again.\n\nLikely causes: target already contains partial files, time skew, low RAM (OOM), disk I/O errors, or package/keyring issues.\n\nLog: $PACSTRAP_LOG."
    die "pacstrap failed after retry (code ${PACSTRAP_RC})"
  fi
fi
log_action "pacstrap installation completed successfully"

# Cleanup temporary swap if created
if [ "${SWAP_CREATED}" = "true" ]; then
  swapoff /mnt/swapfile 2>/dev/null || true
  rm -f /mnt/swapfile 2>/dev/null || true
fi

# generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# copy installer environment log into new system later
cp "$LOG_LIVE" /mnt/tmp/arch-installer-live.log || true

# wallpaper handling: user can optionally provide default.jpg
if [ -f "default.jpg" ]; then
  mkdir -p /mnt/tmp/arch-installer-wallpaper
  cp "default.jpg" /mnt/tmp/arch-installer-wallpaper/default.jpg
  echo "Custom wallpaper found and copied for installation"
fi

# stage installer configs into target for templating
mkdir -p /mnt/tmp/installer
cp -r "$(dirname "$0")/configs" /mnt/tmp/installer/ 2>/dev/null || true
if [ ! -d /mnt/tmp/installer/configs ]; then
  # fallback: download from repo if not running from repo checkout
  mkdir -p /mnt/tmp/installer
  curl -L "https://github.com/Mansminus/CustomArchInstall/archive/refs/heads/main.tar.gz" -o /tmp/installer.tar.gz
  tar -xzf /tmp/installer.tar.gz -C /tmp
  cp -r /tmp/CustomArchInstall-main/configs /mnt/tmp/installer/
fi
# Verify configs are staged
if [ ! -d /mnt/tmp/installer/configs ]; then
  die "Failed to stage configuration templates; cannot continue."
fi

# CHROOT: configure system
# Ensure theme variables are defined in outer shell for heredoc expansion
GTK_THEME_NAME="Breeze-Dark"
ICON_THEME_NAME="Papirus-Dark"
arch-chroot /mnt /bin/bash -e <<'CHROOT'
set -euo pipefail
# Variables from outer environ are not auto-passed, but we will re-create some values inside chroot
# Locale / keyboard / timezone will be written by the outer script using heredoc below
CHROOT_EXIT_ON_ERROR() { echo "Chroot step failed"; exit 1; }

# write timezone, locale, vconsole will be created by outer here via heredoc
CHROOT
# Inject locale/timezone/etc inside chroot with arch-chroot heredoc
arch-chroot /mnt /usr/bin/env \
  SELECTED_LOCALE="${SELECTED_LOCALE}" \
  SELECTED_KBD="${SELECTED_KBD}" \
  TIMEZONE="${TIMEZONE}" \
  USERNAME="${USERNAME}" \
  PASS1="${PASS1}" \
  WM="${WM}" \
  GAMING="${GAMING}" \
  ENABLE_SSH="${ENABLE_SSH}" \
  VM="${VM}" \
  /bin/bash -e <<'CHROOT_CFG'
set -euo pipefail
# --- Locale / Timezone / Keymap ---
echo "${SELECTED_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${SELECTED_LOCALE}" > /etc/locale.conf
echo "KEYMAP=${SELECTED_KBD}" > /etc/vconsole.conf
echo "FONT=lat9w-16" >> /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# --- Hostname ---
echo "arch-custom" > /etc/hostname
cat >/etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch-custom
EOF

# --- Users & sudo ---
useradd -m -G wheel,audio,video,input -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASS1}" | chpasswd
# set root password to same as user for convenience (optional)
echo "root:${PASS1}" | chpasswd
# ensure sudo wheel enabled
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

# --- Enable services ---
systemctl enable NetworkManager
systemctl enable systemd-timesyncd
# Enable printing support
systemctl enable cups
# Enable automatic mounting of removable media
systemctl enable udisks2
# Enable Bluetooth support
systemctl enable bluetooth

# Enable LightDM for graphical login if a desktop WM is selected
if [ "${WM}" != "none" ]; then
  pacman -S --noconfirm lightdm lightdm-gtk-greeter || true
  systemctl enable lightdm || true
fi

# --- Firewall (ufw) ---
pacman -S --noconfirm ufw || true
ufw default deny incoming
ufw default allow outgoing
yes | ufw enable || true

# --- zram for low memory systems (use official zram-generator) ---
if [ $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) -lt 2048 ]; then
  pacman -S --noconfirm zram-generator || true
  cat >/etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
ZRAM
fi

# --- CPU governor ---
pacman -S --noconfirm cpupower || true
if [ "${GAMING}" = "yes" ] ; then
  echo 'GOVERNOR=performance' > /etc/default/cpupower || true
else
  echo 'GOVERNOR=ondemand' > /etc/default/cpupower || true
fi
systemctl enable cpupower || true

# --- Filesystem mount optimisation: noatime where applicable ---
# update fstab: we will naively replace relatime with noatime (safe for most setups)
sed -i 's/relatime/noatime/g' /etc/fstab || true

# --- Install desktop-specific helpers already included by pacstrap in outer script ---
# (Openbox/i3/dwm packages already installed)

# --- VM guest tools enable ---
case "${VM}" in
  qemu)
    systemctl enable qemu-guest-agent || true
    ;;
  vbox)
    systemctl enable vboxservice || true
    ;;
  vmware)
    systemctl enable vmtoolsd || true
    ;;
esac

# --- SSH ---
if [ "${ENABLE_SSH}" = "true" ]; then
  pacman -S --noconfirm openssh || true
  systemctl enable sshd || true
else
  # ensure it's not enabled
  systemctl disable sshd || true
fi

# --- Fonts / theme configuration ---
# Fonts already installed via THEME_PKGS

# Use external templates staged at /tmp/installer/configs
mkdir -p /etc/gtk-2.0 /etc/gtk-3.0 /etc/xdg/qt5ct
: "${GTK_THEME_NAME:=Breeze-Dark}"
: "${ICON_THEME_NAME:=Papirus-Dark}"
if [ -f /tmp/installer/configs/system/gtk-3.0/settings.ini ]; then
  envsubst '${GTK_THEME_NAME} ${ICON_THEME_NAME}' < /tmp/installer/configs/system/gtk-3.0/settings.ini > /etc/gtk-3.0/settings.ini || true
else
  echo "Warning: missing GTK3 settings template; skipping"
fi
if [ -f /tmp/installer/configs/system/gtk-2.0/gtkrc ]; then
  envsubst '${GTK_THEME_NAME} ${ICON_THEME_NAME}' < /tmp/installer/configs/system/gtk-2.0/gtkrc > /etc/gtk-2.0/gtkrc || true
else
  echo "Warning: missing GTK2 settings template; skipping"
fi
if [ -f /tmp/installer/configs/system/xdg/qt5ct/qt5ct.conf ]; then
  cp /tmp/installer/configs/system/xdg/qt5ct/qt5ct.conf /etc/xdg/qt5ct/qt5ct.conf || true
else
  echo "Warning: missing qt5ct template; skipping"
fi

# --- Browser already installed in outer pacstrap

# --- Clean pacman cache if desired (we'll do final cleanup)
CHROOT_CFG
# end chroot configuration

# Post-chroot tweaks: add configs, xinitrc, theming, remove docs/translations if requested
# write .xinitrc and minimal WM configs into /mnt/home/$USERNAME
USER_HOME="/home/${USERNAME}"
arch-chroot /mnt /usr/bin/env WM="${WM}" USERNAME="${USERNAME}" OPENBOX_THEME="${OPENBOX_THEME}" SELECTED_KBD="${SELECTED_KBD}" GTK_THEME_NAME="${GTK_THEME_NAME}" ICON_THEME_NAME="${ICON_THEME_NAME}" STRIP_LOCALE_YES="${STRIP_LOCALE_YES}" ENABLE_SSH="${ENABLE_SSH}" VM="${VM}" GAMING="${GAMING}" /bin/bash -e <<'CHROOT2'
set -euo pipefail
# Define user home inside chroot to avoid unbound variable with 'set -u'
USER_HOME="/home/${USERNAME}"
# create user home defaults
mkdir -p "$USER_HOME"
chown ${USERNAME}:${USERNAME} "$USER_HOME"

# generate .xinitrc for non-display-manager setups
if [ "${WM}" != "none" ]; then
  # Write template without expanding variables, then substitute only selected ones
  EXEC_WM_CMD='exec openbox-session'
  case "${WM}" in
    i3) EXEC_WM_CMD='exec i3' ;;
    dwm) EXEC_WM_CMD='exec dwm' ;;
    openbox|*) EXEC_WM_CMD='exec openbox-session' ;;
  esac
  # do NOT export EXEC_WM_CMD to avoid accidental expansion in strict shells
  if [ -f /tmp/installer/configs/user/xinitrc.tmpl ]; then
    cp /tmp/installer/configs/user/xinitrc.tmpl /tmp/.xinitrc.tmpl
    OPENBOX_THEME="${OPENBOX_THEME}" SELECTED_KBD="${SELECTED_KBD}" envsubst '${OPENBOX_THEME} ${SELECTED_KBD}' < /tmp/.xinitrc.tmpl > "$USER_HOME/.xinitrc"
    rm -f /tmp/.xinitrc.tmpl
  else
    echo "Warning: missing xinitrc template; generating minimal .xinitrc"
    cat > "$USER_HOME/.xinitrc" <<'XINITRC_MIN'
#!/bin/sh
# Minimal X init
if command -v xrdb >/dev/null 2>&1 && [ -f "$HOME/.Xresources" ]; then
  xrdb -merge "$HOME/.Xresources"
fi
if command -v setxkbmap >/dev/null 2>&1; then
  setxkbmap ${SELECTED_KBD}
fi
XINITRC_MIN
  fi
  echo "${EXEC_WM_CMD}" >> "$USER_HOME/.xinitrc"
  chown ${USERNAME}:${USERNAME} "$USER_HOME/.xinitrc"
  chmod +x "$USER_HOME/.xinitrc"
fi

# Enhanced openbox autostart & theming
if [ "${WM}" = "openbox" ]; then
  mkdir -p "$USER_HOME/.config/openbox"

  # Download and install premium Openbox themes
  if [ -n "${OPENBOX_THEME}" ]; then
    echo "Installing ${OPENBOX_THEME} Openbox theme..."
    mkdir -p /tmp/openbox-themes
    cd /tmp/openbox-themes
    if command -v git >/dev/null 2>&1; then
      git clone https://github.com/addy-dclxvi/openbox-theme-collections.git . || \
      curl -L "https://github.com/addy-dclxvi/openbox-theme-collections/archive/master.zip" -o themes.zip && unzip -q themes.zip && mv openbox-theme-collections-master/* .
    else
      curl -L "https://github.com/addy-dclxvi/openbox-theme-collections/archive/master.zip" -o themes.zip && unzip -q themes.zip && mv openbox-theme-collections-master/* .
    fi
    # Install the selected theme to user's themes directory
    mkdir -p "$USER_HOME/.themes"
    if [ -d "${OPENBOX_THEME}" ]; then
      cp -r "${OPENBOX_THEME}" "$USER_HOME/.themes/"
      chown -R ${USERNAME}:${USERNAME} "$USER_HOME/.themes/${OPENBOX_THEME}"
    else
      echo "Selected Openbox theme '${OPENBOX_THEME}' not found in collection; falling back to Clearlooks"
      OPENBOX_THEME="Clearlooks"
    fi
    cd /
    rm -rf /tmp/openbox-themes
    echo "Installed ${OPENBOX_THEME} theme successfully"
  fi

  # Copy autostart and menu from templates if available
  if [ -f /tmp/installer/configs/user/openbox/autostart ]; then
    cp /tmp/installer/configs/user/openbox/autostart "$USER_HOME/.config/openbox/autostart"
  else
    echo "Warning: missing openbox autostart template; skipping"
  fi
  if [ -f /tmp/installer/configs/user/openbox/menu.xml ]; then
    cp /tmp/installer/configs/user/openbox/menu.xml "$USER_HOME/.config/openbox/menu.xml"
  else
    echo "Warning: missing openbox menu template; skipping"
  fi

  # Render rc.xml from template with selected theme and username if available
  if [ -f /tmp/installer/configs/user/openbox/rc.xml.tmpl ]; then
    OPENBOX_THEME="${OPENBOX_THEME}" USERNAME="${USERNAME}" envsubst '${OPENBOX_THEME} ${USERNAME}' < /tmp/installer/configs/user/openbox/rc.xml.tmpl > "$USER_HOME/.config/openbox/rc.xml"
  else
    echo "Warning: missing openbox rc.xml template; skipping"
  fi

  chown -R ${USERNAME}:${USERNAME} "$USER_HOME/.config/openbox"
fi

# Enhanced i3 configuration
if [ "${WM}" = "i3" ]; then
  mkdir -p "$USER_HOME/.config/i3"
  cat > "$USER_HOME/.config/i3/config" <<'I3CFG'
# i3 config with enhanced theming and shortcuts
set \$mod Mod4

# Font for window titles and status bar
font pango:Noto Sans 10

# Use Mouse+\$mod to drag floating windows
floating_modifier \$mod

# Theme colors (Breeze-Dark inspired)
set \$bg-color 	         #2d3748
set \$inactive-bg-color   #2d3748
set \$text-color          #e2e8f0
set \$inactive-text-color #676E7D
set \$urgent-bg-color     #e53e3e
set \$indicator-color     #5a67d8

# Window colors
#                       border              background         text                 indicator
client.focused          \$bg-color          \$bg-color         \$text-color         \$indicator-color
client.unfocused        \$inactive-bg-color \$inactive-bg-color \$inactive-text-color \$indicator-color
client.focused_inactive \$inactive-bg-color \$inactive-bg-color \$inactive-text-color \$indicator-color
client.urgent           \$urgent-bg-color   \$urgent-bg-color  \$text-color         \$indicator-color

# Key bindings
bindsym \$mod+Return exec alacritty
bindsym \$mod+d exec rofi -show drun
bindsym \$mod+Shift+d exec rofi -show run
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+c reload
bindsym \$mod+Shift+r restart
bindsym \$mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -b 'Yes' 'i3-msg exit'"

# Volume controls
bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute exec pactl set-sink-mute @DEFAULT_SINK@ toggle

# Application shortcuts
bindsym \$mod+f exec thunar
bindsym \$mod+w exec firefox
bindsym \$mod+e exec geany

# Window focus
bindsym \$mod+j focus left
bindsym \$mod+k focus down
bindsym \$mod+l focus up
bindsym \$mod+semicolon focus right
bindsym \$mod+Left focus left
bindsym \$mod+Down focus down
bindsym \$mod+Up focus up
bindsym \$mod+Right focus right

# Move windows
bindsym \$mod+Shift+j move left
bindsym \$mod+Shift+k move down
bindsym \$mod+Shift+l move up
bindsym \$mod+Shift+semicolon move right
bindsym \$mod+Shift+Left move left
bindsym \$mod+Shift+Down move down
bindsym \$mod+Shift+Up move up
bindsym \$mod+Shift+Right move right

# Split orientation
bindsym \$mod+h split h
bindsym \$mod+v split v

# Fullscreen mode
bindsym \$mod+\$mod+f fullscreen toggle

# Workspaces
set \$ws1 "1"
set \$ws2 "2"
set \$ws3 "3"
set \$ws4 "4"
set \$ws5 "5"
set \$ws6 "6"
set \$ws7 "7"
set \$ws8 "8"
set \$ws9 "9"
set \$ws10 "10"

# Switch to workspace
bindsym \$mod+1 workspace \$ws1
bindsym \$mod+2 workspace \$ws2
bindsym \$mod+3 workspace \$ws3
bindsym \$mod+4 workspace \$ws4
bindsym \$mod+5 workspace \$ws5
bindsym \$mod+6 workspace \$ws6
bindsym \$mod+7 workspace \$ws7
bindsym \$mod+8 workspace \$ws8
bindsym \$mod+9 workspace \$ws9
bindsym \$mod+0 workspace \$ws10

# Move container to workspace
bindsym \$mod+Shift+1 move container to workspace \$ws1
bindsym \$mod+Shift+2 move container to workspace \$ws2
bindsym \$mod+Shift+3 move container to workspace \$ws3
bindsym \$mod+Shift+4 move container to workspace \$ws4
bindsym \$mod+Shift+5 move container to workspace \$ws5
bindsym \$mod+Shift+6 move container to workspace \$ws6
bindsym \$mod+Shift+7 move container to workspace \$ws7
bindsym \$mod+Shift+8 move container to workspace \$ws8
bindsym \$mod+Shift+9 move container to workspace \$ws9
bindsym \$mod+Shift+0 move container to workspace \$ws10

# Status bar (polished positioning and appearance)
bar {
    status_command i3status
    position bottom
    height 32
    workspace_buttons yes
    strip_workspace_numbers yes
    separator_symbol " | "
    
    colors {
        background \$bg-color
        separator #4a5568
        statusline \$text-color
        #                  border             background         text
        focused_workspace  \$indicator-color  \$indicator-color  \$text-color
        inactive_workspace \$inactive-bg-color \$inactive-bg-color \$inactive-text-color
        urgent_workspace   \$urgent-bg-color  \$urgent-bg-color  \$text-color
        active_workspace   \$bg-color         \$bg-color         \$text-color
    }
    
    font pango:Noto Sans 9
    tray_output primary
    tray_padding 4
}

# Autostart applications
exec --no-startup-id picom -b
exec --no-startup-id nm-applet
exec --no-startup-id volumeicon
exec --no-startup-id parcellite
exec --no-startup-id dunst
exec --no-startup-id blueman-applet
exec --no-startup-id sh -c 'if [ -f /usr/share/backgrounds/arch-custom/default.jpg ]; then feh --bg-scale /usr/share/backgrounds/arch-custom/default.jpg; else xsetroot -solid "#1a1a1a"; fi'
I3CFG
  chown -R ${USERNAME}:${USERNAME} "$USER_HOME/.config/i3"
fi

# --- User Theme Configuration ---
# Create user-specific theme directories
mkdir -p "$USER_HOME/.config/gtk-2.0" "$USER_HOME/.config/gtk-3.0"
mkdir -p "$USER_HOME/.config/tint2" "$USER_HOME/.icons/default"
mkdir -p "$USER_HOME/.config/rofi" "$USER_HOME/.config/alacritty"

# User GTK configuration (coordinated with openbox theme choice)
if [ -f /tmp/installer/configs/user/gtk-3.0/settings.ini.tmpl ]; then
  GTK_THEME_NAME="${GTK_THEME_NAME}" ICON_THEME_NAME="${ICON_THEME_NAME}" envsubst '${GTK_THEME_NAME} ${ICON_THEME_NAME}' < /tmp/installer/configs/user/gtk-3.0/settings.ini.tmpl > "$USER_HOME/.config/gtk-3.0/settings.ini" || true
else
  echo "Warning: missing user GTK3 template; skipping"
fi
if [ -f /tmp/installer/configs/user/gtk-2.0/gtkrc.tmpl ]; then
  GTK_THEME_NAME="${GTK_THEME_NAME}" ICON_THEME_NAME="${ICON_THEME_NAME}" envsubst '${GTK_THEME_NAME} ${ICON_THEME_NAME}' < /tmp/installer/configs/user/gtk-2.0/gtkrc.tmpl > "$USER_HOME/.gtkrc-2.0" || true
else
  echo "Warning: missing user GTK2 template; skipping"
fi

# Cursor theme configuration
mkdir -p "$USER_HOME/.icons/default"
if [ -f /tmp/installer/configs/user/icons/default/index.theme ]; then
  cp /tmp/installer/configs/user/icons/default/index.theme "$USER_HOME/.icons/default/index.theme" || true
else
  echo "Warning: missing cursor theme index; skipping"
fi

# Enhanced Tint2 configuration coordinated with selected theme
ACCENT_COLOR_GREEN="#4a5d4a"
ACCENT_COLOR_RED="#5d4a4a"
ACCENT_BORDER_GREEN="#6a8759"
ACCENT_BORDER_RED="#cc7832"

if [ "${OPENBOX_THEME}" = "Raven" ]; then
  ACCENT_COLOR="$ACCENT_COLOR_GREEN"
  ACCENT_BORDER="$ACCENT_BORDER_GREEN"
else
  ACCENT_COLOR="$ACCENT_COLOR_RED"
  ACCENT_BORDER="$ACCENT_BORDER_RED"
fi
if [ -f /tmp/installer/configs/user/tint2/tint2rc.tmpl ]; then
  ACCENT_COLOR="$ACCENT_COLOR" ACCENT_BORDER="$ACCENT_BORDER" envsubst '${ACCENT_COLOR} ${ACCENT_BORDER}' < /tmp/installer/configs/user/tint2/tint2rc.tmpl > "$USER_HOME/.config/tint2/tint2rc" || true
else
  echo "Warning: missing tint2 template; skipping"
fi

# Rofi configuration for modern app launcher (theme-coordinated)
if [ -f /tmp/installer/configs/user/rofi/config.rasi.tmpl ]; then
  ICON_THEME_NAME="${ICON_THEME_NAME}" envsubst '${ICON_THEME_NAME}' < /tmp/installer/configs/user/rofi/config.rasi.tmpl > "$USER_HOME/.config/rofi/config.rasi" || true
else
  echo "Warning: missing rofi template; skipping"
fi

# Alacritty terminal configuration
if [ -f /tmp/installer/configs/user/alacritty/alacritty.yml ]; then
  cp /tmp/installer/configs/user/alacritty/alacritty.yml "$USER_HOME/.config/alacritty/alacritty.yml" || true
else
  echo "Warning: missing alacritty config; skipping"
fi

# Create launcher script for tint2 panel
mkdir -p "$USER_HOME/.config/tint2"
if [ -f /tmp/installer/configs/user/tint2/launcher.sh ]; then
  cp /tmp/installer/configs/user/tint2/launcher.sh "$USER_HOME/.config/tint2/launcher.sh" || true
  chmod +x "$USER_HOME/.config/tint2/launcher.sh" || true
else
  echo "Warning: missing tint2 launcher script; skipping"
fi

# Create polished dunst notification configuration
mkdir -p "$USER_HOME/.config/dunst"
if [ -f /tmp/installer/configs/user/dunst/dunstrc ]; then
  cp /tmp/installer/configs/user/dunst/dunstrc "$USER_HOME/.config/dunst/dunstrc" || true
else
  echo "Warning: missing dunst config; skipping"
fi

# Set ownership for all user configuration files
chown -R ${USERNAME}:${USERNAME} "$USER_HOME/.config"
chown -R ${USERNAME}:${USERNAME} "$USER_HOME/.icons"
[ -f "$USER_HOME/.gtkrc-2.0" ] && chown ${USERNAME}:${USERNAME} "$USER_HOME/.gtkrc-2.0" || true

# Create .bashrc additions for theme environment variables
cat >> "$USER_HOME/.bashrc" <<'BASHTHEME'

# Theme environment variables
export GTK_THEME="Breeze-Dark"
export QT_QPA_PLATFORMTHEME="qt5ct"
export QT_AUTO_SCREEN_SCALE_FACTOR=0

# Aliases for convenience (user-friendly)
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias apps='rofi -show drun'
alias screenshot='flameshot gui'
alias lock='i3lock -c 000000'
alias files='thunar'
alias calc='galculator'
alias clipboard='parcellite'
alias bluetooth='blueman-manager'
alias paint='mtpaint'

# Software installation helpers (for advanced users)
alias install-software='sudo pacman -S'
alias search-software='pacman -Ss'
alias update-system='sudo pacman -Syu'

BASHTHEME
chown ${USERNAME}:${USERNAME} "$USER_HOME/.bashrc"

# Create user directories for better UX
mkdir -p "$USER_HOME/Pictures" "$USER_HOME/Documents" "$USER_HOME/Downloads"
mkdir -p "$USER_HOME/Desktop" "$USER_HOME/Music" "$USER_HOME/Videos"
chown -R ${USERNAME}:${USERNAME} "$USER_HOME/Pictures" "$USER_HOME/Documents" "$USER_HOME/Downloads"
chown -R ${USERNAME}:${USERNAME} "$USER_HOME/Desktop" "$USER_HOME/Music" "$USER_HOME/Videos"

# Set up XDG user directories properly
su - ${USERNAME} -c "xdg-user-dirs-update" || true

# strip manpages/translations/docs if requested by user
if [ "${STRIP_LOCALE_YES}" = "true" ]; then
  # Remove man pages/info
  pacman -Rns --noconfirm man-db man-pages texinfo || true
  # remove locale files except chosen locale
  KEEP_LOCALE="${SELECTED_LOCALE%%.*}"
  for d in /usr/share/locale/* ; do
    case "\$d" in
      *"\$KEEP_LOCALE"*) continue ;;
    esac
    rm -rf "\$d" || true
  done
  # remove docs
  rm -rf /usr/share/doc/* /usr/share/info/* /usr/share/gtk-doc/* || true
fi

# cleanup pacman cache
pacman -Scc --noconfirm || true

# enable fstrim on SSDs if applicable
if grep -q 'ssd' /sys/block/*/queue/rotational 2>/dev/null; then
  systemctl enable fstrim.timer || true
fi

# regenerate machine-id
systemd-machine-id-setup || true

CHROOT2

# Install GRUB
log_action "Installing GRUB bootloader (UEFI=$UEFI)"
if $UEFI; then
  arch-chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch --recheck" || die "GRUB install failed (UEFI)"
else
  arch-chroot /mnt /bin/bash -c "grub-install --target=i386-pc $TARGET_DISK" || die "GRUB install failed (BIOS)"
fi
arch-chroot /mnt /bin/bash -c "grub-mkconfig -o /boot/grub/grub.cfg" || die "grub-mkconfig failed"
log_action "GRUB installation and configuration completed"

# final message + copy log into installed system
log_action "Installation completed successfully - system ready for reboot"
cp "$LOG_LIVE" /mnt/var/log/arch-installer.log || true

# Build final message with theme info
THEME_MSG=""
if [ "$WM" = "openbox" ] && [ -n "$OPENBOX_THEME" ]; then
  THEME_MSG="\nOpenbox theme: ${OPENBOX_THEME}"
fi

dialog --title "Installation finished" --msgbox "Installation complete!\n\nUser: ${USERNAME}\nLocale: ${SELECTED_LOCALE}\nKeyboard: ${SELECTED_KBD}\nTimezone: ${TIMEZONE}\nWM: ${WM}${THEME_MSG}\nRAM detected: ${TOTAL_RAM_MB} MB\n\nTheme: Breeze-Dark + Papirus-Dark + Breeze cursors\n\nA log has been saved to /var/log/arch-installer.log on the installed system.\n\nReboot now." 18 75

clear
echo "Installation complete. Reboot the machine to boot into your new Arch system."
