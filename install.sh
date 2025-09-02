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
arch-chroot /mnt /bin/bash -e <<CHROOT_CFG
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

# --- Firewall (ufw) ---
pacman -S --noconfirm ufw || true
ufw default deny incoming
ufw default allow outgoing
yes | ufw enable || true

# --- zram for low memory systems (if systemd-zram-generator available) ---
if [ $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) -lt 2048 ]; then
  pacman -S --noconfirm systemd-zram-generator || true
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

#!/bin/bash
# --- GTK Theme Configuration ---
# Set up theme matching the openbox selection
mkdir -p /etc/gtk-2.0 /etc/gtk-3.0

# Set sane defaults in case env vars are missing
: "${GTK_THEME_NAME:=Breeze-Dark}"
: "${ICON_THEME_NAME:=Papirus-Dark}"

cat > /etc/gtk-3.0/settings.ini <<GTKCONF
[Settings]
gtk-theme-name = ${GTK_THEME_NAME}
gtk-icon-theme-name = ${ICON_THEME_NAME}
gtk-cursor-theme-name = Breeze
gtk-font-name = Noto Sans 10
GTKCONF

cat > /etc/gtk-2.0/gtkrc <<GTK2CONF
gtk-theme-name = "${GTK_THEME_NAME}"
gtk-icon-theme-name = "${ICON_THEME_NAME}"
gtk-cursor-theme-name = "Breeze"
gtk-font-name = "Noto Sans 10"
GTK2CONF

# --- Qt Theme Configuration ---
mkdir -p /etc/xdg/qt5ct
cat > /etc/xdg/qt5ct/qt5ct.conf <<QT5CONF
[Appearance]
color_scheme_path=/usr/share/qt5ct/colors/darker.conf
custom_palette=false
icon_theme=${ICON_THEME_NAME}
standard_dialogs=default
style=Breeze

[Fonts]
fixed=@Variant(\0\0\0@\0\0\0\x12\0N\0o\0t\0o\0 \0S\0\x61\0n\0s\0 \0M\0o\0n\0o@$\0\0\0\0\0\0\xff\xff\xff\xff\x5\x1\0\x32\x10)
general=@Variant(\0\0\0@\0\0\0\x12\0N\0o\0t\0o\0 \0S\0\x61\0n\0s@$\0\0\0\0\0\0\xff\xff\xff\xff\x5\x1\0\x32\x10)
QT5CONF

# --- Browser already installed in outer pacstrap

# --- Clean pacman cache if desired (we'll do final cleanup)
CHROOT_CFG
# end chroot configuration

# Post-chroot tweaks: add configs, xinitrc, theming, remove docs/translations if requested
# write .xinitrc and minimal WM configs into /mnt/home/$USERNAME
arch-chroot /mnt /bin/bash -e <<CHROOT2
set -euo pipefail
# create user home defaults
USER_HOME="/home/${USERNAME}"
mkdir -p "\$USER_HOME"
chown ${USERNAME}:${USERNAME} "\$USER_HOME"

# generate .xinitrc for non-display-manager setups
if [ "${WM}" != "none" ]; then
  cat > "\$USER_HOME/.xinitrc" <<XINIT
#!/bin/sh
# auto-generated .xinitrc with theme support
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"

# Set environment variables for theming
export GTK_THEME="Breeze-Dark"
export QT_QPA_PLATFORMTHEME="qt5ct"
export QT_AUTO_SCREEN_SCALE_FACTOR=0

# keyboard
setxkbmap ${SELECTED_KBD} 2>/dev/null || true

# Start compositor for transparency and effects (optional)
if command -v picom >/dev/null 2>&1; then
  picom -b &
fi

# set wallpaper (feh) - with fallback to solid color if image missing
if command -v feh >/dev/null 2>&1; then
  if [ -f /usr/share/backgrounds/arch-custom/default.jpg ]; then
  feh --bg-scale /usr/share/backgrounds/arch-custom/default.jpg &
  else
    # Fallback to solid color matching theme
    if [ "${OPENBOX_THEME}" = "Raven" ]; then
      xsetroot -solid "#1a2e1a" &  # Dark green
    elif [ "${OPENBOX_THEME}" = "Triste" ]; then
      xsetroot -solid "#2e1a1a" &  # Dark red
    else
      xsetroot -solid "#1a1a1a" &  # Dark gray
    fi
  fi
fi

# start nm-applet (NetworkManager applet) if available
if command -v nm-applet >/dev/null 2>&1; then
  nm-applet >/dev/null 2>&1 &
fi

# start volume control applet
if command -v pasystray >/dev/null 2>&1; then
  pasystray >/dev/null 2>&1 &
elif command -v pavucontrol >/dev/null 2>&1; then
  # Just make pavucontrol easily accessible via right-click menu
  true
fi

# start clipboard manager
if command -v parcellite >/dev/null 2>&1; then
  parcellite >/dev/null 2>&1 &
fi

# start notification daemon
if command -v dunst >/dev/null 2>&1; then
  dunst >/dev/null 2>&1 &
fi

# start bluetooth applet if available
if command -v blueman-applet >/dev/null 2>&1; then
  blueman-applet >/dev/null 2>&1 &
fi

# start panel if tint2 exists
if command -v tint2 >/dev/null 2>&1; then
  tint2 >/dev/null 2>&1 &
fi

# start the window manager chosen by installer
case "\$1" in
  i3) exec i3 ;;
  dwm) exec dwm ;;
  openbox) exec openbox-session ;;
  *) exec openbox-session ;;
esac
XINIT
  chown ${USERNAME}:${USERNAME} "\$USER_HOME/.xinitrc"
  chmod +x "\$USER_HOME/.xinitrc"
fi

# Enhanced openbox autostart & theming
if [ "${WM}" = "openbox" ]; then
  mkdir -p "\$USER_HOME/.config/openbox"
  
  # Download and install premium Openbox themes
  if [ -n "${OPENBOX_THEME}" ]; then
    echo "Installing ${OPENBOX_THEME} Openbox theme..."
    mkdir -p /tmp/openbox-themes
    cd /tmp/openbox-themes
    
    # Download the theme collection
    if command -v git >/dev/null 2>&1; then
      git clone https://github.com/addy-dclxvi/openbox-theme-collections.git . || \
      curl -L "https://github.com/addy-dclxvi/openbox-theme-collections/archive/master.zip" -o themes.zip && unzip -q themes.zip && mv openbox-theme-collections-master/* .
    else
      curl -L "https://github.com/addy-dclxvi/openbox-theme-collections/archive/master.zip" -o themes.zip && unzip -q themes.zip && mv openbox-theme-collections-master/* .
    fi
    
    # Install the selected theme to user's themes directory
    mkdir -p "\$USER_HOME/.themes"
    if [ -d "${OPENBOX_THEME}" ]; then
      cp -r "${OPENBOX_THEME}" "\$USER_HOME/.themes/"
      chown -R ${USERNAME}:${USERNAME} "\$USER_HOME/.themes/${OPENBOX_THEME}"
    fi
    
    # Clean up
    cd /
    rm -rf /tmp/openbox-themes
    
    echo "Installed ${OPENBOX_THEME} theme successfully"
  fi
  
  cat > "\$USER_HOME/.config/openbox/autostart" <<'OBAS'
# Openbox autostart with full desktop experience
# Start compositor for transparency and smooth effects
picom -b &

# Set wallpaper with fallback
if [ -f /usr/share/backgrounds/arch-custom/default.jpg ]; then
feh --bg-scale /usr/share/backgrounds/arch-custom/default.jpg &
else
  # Fallback to solid color matching theme
  if [ "${OPENBOX_THEME}" = "Raven" ]; then
    xsetroot -solid "#1a2e1a" &  # Dark green
  elif [ "${OPENBOX_THEME}" = "Triste" ]; then
    xsetroot -solid "#2e1a1a" &  # Dark red
  else
    xsetroot -solid "#1a1a1a" &  # Dark gray
  fi
fi

# Start network applet
nm-applet &

# Start volume control in system tray
volumeicon &

# Start clipboard manager
parcellite &

# Start notification daemon
dunst &

# Start bluetooth applet (if available)
blueman-applet &

# Start panel
tint2 &

# Set cursor theme
xsetroot -cursor_name left_ptr &
OBAS

  # Create enhanced openbox menu configuration
  cat > "\$USER_HOME/.config/openbox/menu.xml" <<'OBMENU'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="Applications">
  <item label="Terminal">
    <action name="Execute"><command>alacritty</command></action>
  </item>
  <item label="File Manager">
    <action name="Execute"><command>thunar</command></action>
  </item>
  <item label="Web Browser">
    <action name="Execute"><command>sh -c 'command -v firefox >/dev/null 2>&1 && exec firefox || exec falkon'</command></action>
  </item>
  <item label="Text Editor">
    <action name="Execute"><command>geany</command></action>
  </item>
  <item label="Image Viewer">
    <action name="Execute"><command>ristretto</command></action>
  </item>
  <item label="Video Player">
    <action name="Execute"><command>vlc</command></action>
  </item>
  <item label="PDF Reader">
    <action name="Execute"><command>evince</command></action>
  </item>
  <item label="Calculator">
    <action name="Execute"><command>galculator</command></action>
  </item>
  <item label="Image Editor">
    <action name="Execute"><command>mtpaint</command></action>
  </item>
  <separator/>
  <item label="Application Launcher">
    <action name="Execute"><command>rofi -show drun</command></action>
  </item>
  <item label="Screenshot">
    <action name="Execute"><command>flameshot gui</command></action>
  </item>
  <separator/>
  <item label="Settings">
    <action name="Execute"><command>lxappearance</command></action>
  </item>
  <item label="Clipboard Manager">
    <action name="Execute"><command>parcellite</command></action>
  </item>
  <item label="Display Settings">
    <action name="Execute"><command>arandr</command></action>
  </item>
  <item label="Volume Control">
    <action name="Execute"><command>pavucontrol</command></action>
  </item>
  <item label="Bluetooth Manager">
    <action name="Execute"><command>blueman-manager</command></action>
  </item>
  <item label="System Monitor">
    <action name="Execute"><command>gnome-system-monitor</command></action>
  </item>
  <item label="Disk Usage">
    <action name="Execute"><command>baobab</command></action>
  </item>
  <item label="Disk Manager">
    <action name="Execute"><command>gparted</command></action>
  </item>
  <separator/>
  <item label="Reconfigure">
    <action name="Reconfigure"/>
  </item>
  <item label="Exit">
    <action name="Exit"/>
  </item>
</menu>
</openbox_menu>
OBMENU

  # Create Openbox configuration with selected theme
  cat > "\$USER_HOME/.config/openbox/rc.xml" <<OBRCXML
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc"
                xmlns:xi="http://www.w3.org/2001/XInclude">
  <resistance>
    <strength>10</strength>
    <screen_edge_strength>20</screen_edge_strength>
  </resistance>
  
  <focus>
    <focusNew>yes</focusNew>
    <followMouse>no</followMouse>
    <focusLast>yes</focusLast>
    <underMouse>no</underMouse>
    <focusDelay>200</focusDelay>
    <raiseOnFocus>no</raiseOnFocus>
  </focus>
  
  <placement>
    <policy>Smart</policy>
    <center>yes</center>
    <monitor>Primary</monitor>
    <primaryMonitor>1</primaryMonitor>
  </placement>
  
  <theme>
    <name>${OPENBOX_THEME:-Clearlooks}</name>
    <titleLayout>NLIMC</titleLayout>
    <keepBorder>yes</keepBorder>
    <animateIconify>yes</animateIconify>
    <font place="ActiveWindow">
      <name>Noto Sans</name>
      <size>9</size>
      <weight>bold</weight>
      <slant>normal</slant>
    </font>
    <font place="InactiveWindow">
      <name>Noto Sans</name>
      <size>9</size>
      <weight>normal</weight>
      <slant>normal</slant>
    </font>
    <font place="MenuHeader">
      <name>Noto Sans</name>
      <size>10</size>
      <weight>bold</weight>
      <slant>normal</slant>
    </font>
    <font place="MenuItem">
      <name>Noto Sans</name>
      <size>9</size>
      <weight>normal</weight>
      <slant>normal</slant>
    </font>
    <font place="ActiveOnScreenDisplay">
      <name>Noto Sans</name>
      <size>9</size>
      <weight>bold</weight>
      <slant>normal</slant>
    </font>
    <font place="InactiveOnScreenDisplay">
      <name>Noto Sans</name>
      <size>9</size>
      <weight>normal</weight>
      <slant>normal</slant>
    </font>
  </theme>
  
  <desktops>
    <number>4</number>
    <firstdesk>1</firstdesk>
    <names>
      <name>Desktop 1</name>
      <name>Desktop 2</name>
      <name>Desktop 3</name>
      <name>Desktop 4</name>
    </names>
    <popupTime>875</popupTime>
  </desktops>
  
  <resize>
    <drawContents>yes</drawContents>
    <popupShow>Nonpixel</popupShow>
    <popupPosition>Center</popupPosition>
    <popupFixedPosition>
      <x>10</x>
      <y>10</y>
    </popupFixedPosition>
  </resize>
  
  <margins>
    <top>0</top>
    <bottom>0</bottom>
    <left>0</left>
    <right>0</right>
  </margins>
  
  <dock>
    <position>TopLeft</position>
    <floatingX>0</floatingX>
    <floatingY>0</floatingY>
    <noStrut>no</noStrut>
    <stacking>Above</stacking>
    <direction>Vertical</direction>
    <autoHide>no</autoHide>
    <hideDelay>300</hideDelay>
    <showDelay>300</showDelay>
    <moveButton>Middle</moveButton>
  </dock>
  
  <keyboard>
    <chainQuitKey>C-g</chainQuitKey>
    
    <!-- Window management -->
    <keybind key="A-F4">
      <action name="Close"/>
    </keybind>
    <keybind key="A-Tab">
      <action name="NextWindow">
        <finalactions>
          <action name="Focus"/>
          <action name="Raise"/>
          <action name="Unshade"/>
        </finalactions>
      </action>
    </keybind>
    
    <!-- Application launchers -->
    <keybind key="W-Return">
      <action name="Execute">
        <command>alacritty</command>
      </action>
    </keybind>
    <keybind key="W-d">
      <action name="Execute">
        <command>rofi -show drun</command>
      </action>
    </keybind>
    <keybind key="W-f">
      <action name="Execute">
        <command>thunar</command>
      </action>
    </keybind>
    <keybind key="W-w">
      <action name="Execute">
        <command>sh -c 'command -v firefox >/dev/null 2>&1 && exec firefox || exec falkon'</command>
      </action>
    </keybind>
    <keybind key="W-e">
      <action name="Execute">
        <command>geany</command>
      </action>
    </keybind>
    
    <!-- Screenshot shortcuts -->
    <keybind key="Print">
      <action name="Execute">
        <command>flameshot gui</command>
      </action>
    </keybind>
    <keybind key="W-Print">
      <action name="Execute">
        <command>flameshot full -p ~/Pictures</command>
      </action>
    </keybind>
    
    <!-- System shortcuts -->
    <keybind key="W-l">
      <action name="Execute">
        <command>i3lock -c 000000</command>
      </action>
    </keybind>
    <keybind key="W-v">
      <action name="Execute">
        <command>parcellite</command>
      </action>
    </keybind>
    <keybind key="W-b">
      <action name="Execute">
        <command>blueman-manager</command>
      </action>
    </keybind>
    <keybind key="W-i">
      <action name="Execute">
        <command>mtpaint</command>
      </action>
    </keybind>
    
    <!-- Desktop switching -->
    <keybind key="C-A-Left">
      <action name="GoToDesktop"><to>left</to><wrap>no</wrap></action>
    </keybind>
    <keybind key="C-A-Right">
      <action name="GoToDesktop"><to>right</to><wrap>no</wrap></action>
    </keybind>
  </keyboard>
  
  <mouse>
    <dragThreshold>1</dragThreshold>
    <doubleClickTime>500</doubleClickTime>
    <screenEdgeWarpTime>400</screenEdgeWarpTime>
    <screenEdgeWarpMouse>false</screenEdgeWarpMouse>
    
    <context name="Frame">
      <mousebind button="A-Left" action="Press">
        <action name="Focus"/>
        <action name="Raise"/>
      </mousebind>
      <mousebind button="A-Left" action="Drag">
        <action name="Move"/>
      </mousebind>
      <mousebind button="A-Right" action="Press">
        <action name="Focus"/>
        <action name="Raise"/>
        <action name="Unshade"/>
      </mousebind>
      <mousebind button="A-Right" action="Drag">
        <action name="Resize"/>
      </mousebind>
      <mousebind button="A-Middle" action="Press">
        <action name="Lower"/>
        <action name="FocusToBottom"/>
        <action name="Unfocus"/>
      </mousebind>
    </context>
    
    <context name="Titlebar">
      <mousebind button="Left" action="Drag">
        <action name="Move"/>
      </mousebind>
      <mousebind button="Left" action="DoubleClick">
        <action name="ToggleMaximize"/>
      </mousebind>
      <mousebind button="Up" action="Click">
        <action name="if">
          <shaded>no</shaded>
          <then>
            <action name="Shade"/>
            <action name="FocusToBottom"/>
            <action name="Unfocus"/>
            <action name="Lower"/>
          </then>
        </action>
      </mousebind>
      <mousebind button="Down" action="Click">
        <action name="if">
          <shaded>yes</shaded>
          <then>
            <action name="Unshade"/>
            <action name="Raise"/>
          </then>
        </action>
      </mousebind>
    </context>
    
    <context name="Root">
      <mousebind button="Middle" action="Press">
        <action name="ShowMenu"><menu>client-list-combined-menu</menu></action>
      </mousebind>
      <mousebind button="Right" action="Press">
        <action name="ShowMenu"><menu>root-menu</menu></action>
      </mousebind>
    </context>
  </mouse>
  
  <menu>
    <file>/home/${USERNAME}/.config/openbox/menu.xml</file>
    <hideDelay>200</hideDelay>
    <middle>no</middle>
    <submenuShowDelay>100</submenuShowDelay>
    <submenuHideDelay>400</submenuHideDelay>
    <applicationIcons>yes</applicationIcons>
    <manageDesktops>yes</manageDesktops>
  </menu>
  
  <applications>
    <application class="*">
      <decor>yes</decor>
    </application>
  </applications>
</openbox_config>
OBRCXML

  chown -R ${USERNAME}:${USERNAME} "\$USER_HOME/.config/openbox"
fi

# Enhanced i3 configuration
if [ "${WM}" = "i3" ]; then
  mkdir -p "\$USER_HOME/.config/i3"
  cat > "\$USER_HOME/.config/i3/config" <<'I3CFG'
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
  chown -R ${USERNAME}:${USERNAME} "\$USER_HOME/.config/i3"
fi

# --- User Theme Configuration ---
# Create user-specific theme directories
mkdir -p "\$USER_HOME/.config/gtk-2.0" "\$USER_HOME/.config/gtk-3.0"
mkdir -p "\$USER_HOME/.config/tint2" "\$USER_HOME/.icons/default"
mkdir -p "\$USER_HOME/.config/rofi" "\$USER_HOME/.config/alacritty"

# User GTK configuration (coordinated with openbox theme choice)
cat > "\$USER_HOME/.config/gtk-3.0/settings.ini" <<USERGTK3
[Settings]
gtk-theme-name=${GTK_THEME_NAME}
gtk-icon-theme-name=${ICON_THEME_NAME}
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=Breeze
gtk-cursor-theme-size=24
gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images=0
gtk-menu-images=0
gtk-enable-event-sounds=1
gtk-enable-input-feedback-sounds=1
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintfull
gtk-xft-rgba=rgb
USERGTK3

cat > "\$USER_HOME/.gtkrc-2.0" <<USERGTK2
gtk-theme-name="${GTK_THEME_NAME}"
gtk-icon-theme-name="${ICON_THEME_NAME}"
gtk-font-name="Noto Sans 10"
gtk-cursor-theme-name="Breeze"
gtk-cursor-theme-size=24
gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images=0
gtk-menu-images=0
gtk-enable-event-sounds=1
gtk-enable-input-feedback-sounds=1
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle="hintfull"
gtk-xft-rgba="rgb"
USERGTK2

# Cursor theme configuration
cat > "\$USER_HOME/.icons/default/index.theme" <<'CURSORTHEME'
[Icon Theme]
Name=Default
Comment=Default Cursor Theme
Inherits=Breeze
CURSORTHEME

# Enhanced Tint2 configuration coordinated with selected theme
# Colors adapt to Raven (green) or Triste (red) themes
ACCENT_COLOR_GREEN="#4a5d4a"
ACCENT_COLOR_RED="#5d4a4a"
ACCENT_BORDER_GREEN="#6a8759"
ACCENT_BORDER_RED="#cc7832"

if [ "${OPENBOX_THEME}" = "Raven" ]; then
  ACCENT_COLOR="\$ACCENT_COLOR_GREEN"
  ACCENT_BORDER="\$ACCENT_BORDER_GREEN"
else
  ACCENT_COLOR="\$ACCENT_COLOR_RED"
  ACCENT_BORDER="\$ACCENT_BORDER_RED"
fi

cat > "\$USER_HOME/.config/tint2/tint2rc" <<TINT2CONF
# Tint2 config for polished desktop - coordinates with ${OPENBOX_THEME:-default} theme
rounded = 0
border_width = 0
border_sides = TBLR
background_color = #1a1a1a 95
border_color = #000000 0

panel_items = LTSC
panel_size = 100% 36
panel_margin = 0 0
panel_padding = 8 6 8
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_position = bottom center horizontal
panel_layer = normal
panel_monitor = all
panel_shrink = 0
autohide = 0
autohide_show_timeout = 0
autohide_hide_timeout = 2
autohide_height = 2
strut_policy = follow_size
panel_window_name = tint2
disable_transparency = 0
mouse_effects = 1
font_shadow = 0
mouse_hover_icon_asb = 100 0 15
mouse_pressed_icon_asb = 100 0 0

taskbar_mode = single_desktop
taskbar_hide_if_empty = 0
taskbar_padding = 0 0 2
taskbar_background_id = 0
taskbar_active_background_id = 0
taskbar_name = 1
taskbar_hide_inactive_tasks = 0
taskbar_hide_different_monitor = 0
taskbar_always_show_all_desktop_tasks = 0
taskbar_name_padding = 6 3
taskbar_name_background_id = 0
taskbar_name_active_background_id = 0
taskbar_name_font = Noto Sans 9
taskbar_name_font_color = #d4d4d4 100
taskbar_name_active_font_color = #ffffff 100
taskbar_distribute_size = 0
taskbar_sort_order = none
task_align = left

task_text = 1
task_icon = 1
task_centered = 1
urgent_nb_of_blink = 100000
task_maximum_size = 160 32
task_padding = 4 3 6
task_tooltip = 1
task_thumbnail = 0
task_thumbnail_size = 210
task_font = Noto Sans 9
task_font_color = #d4d4d4 100
task_background_id = 0
task_active_background_id = 2
task_urgent_background_id = 3
task_iconified_background_id = 0
mouse_left = toggle_iconify
mouse_middle = none
mouse_right = close
mouse_scroll_up = toggle
mouse_scroll_down = iconify

# Launcher configuration (application menu button)
launcher_padding = 8 6 8
launcher_background_id = 0
launcher_icon_background_id = 0
launcher_icon_size = 22
launcher_icon_asb = 100 0 10
launcher_icon_theme_override = 0
launcher_tooltip = 1
launcher_item_app = ~/.config/tint2/launcher.sh

systray_padding = 0 8 4
systray_background_id = 0
systray_sort = ascending
systray_icon_size = 20
systray_icon_asb = 100 0 0
systray_monitor = 1
systray_name_filter = 

clock_format = %H:%M
clock_tooltip = %A %d %B
clock_padding = 12 0
clock_background_id = 0
clock_font = Noto Sans 10
clock_font_color = #d4d4d4 100
clock_rclick_command = zenity --calendar

# Active task background (adapts to theme)
background_id = 2
rounded = 3
border_width = 1
border_sides = TBLR
background_color = \${ACCENT_COLOR} 70
border_color = \${ACCENT_BORDER} 100

# Urgent task background
background_id = 3
rounded = 3
border_width = 1
border_sides = TBLR
background_color = #8b3a3a 70
border_color = #cc5555 100
TINT2CONF

# Rofi configuration for modern app launcher (theme-coordinated)
cat > "\$USER_HOME/.config/rofi/config.rasi" <<ROFICONF
configuration {
    modi: "run,drun,window";
    width: 50;
    lines: 15;
    columns: 1;
    font: "Noto Sans 12";
    bw: 1;
    location: 0;
    padding: 5;
    yoffset: 0;
    xoffset: 0;
    fixed-num-lines: true;
    show-icons: true;
    terminal: "alacritty";
    ssh-client: "ssh";
    ssh-command: "{terminal} -e {ssh-client} {host} [-p {port}]";
    run-command: "{cmd}";
    run-list-command: "";
    run-shell-command: "{terminal} -e {cmd}";
    window-command: "wmctrl -i -R {window}";
    window-match-fields: "all";
    icon-theme: "${ICON_THEME_NAME}";
    drun-match-fields: "name,generic,exec,categories";
    drun-show-actions: false;
    drun-display-format: "{icon} {name}";
    disable-history: false;
    ignored-prefixes: "";
    sort: false;
    case-sensitive: false;
    cycle: true;
    sidebar-mode: false;
    eh: 1;
    auto-select: false;
    parse-hosts: false;
    parse-known-hosts: true;
    combi-modi: "window,run";
    matching: "normal";
    tokenize: true;
    m: "-5";
    line-margin: 2;
    line-padding: 1;
    filter: "";
    separator-style: "dash";
    hide-scrollbar: false;
    fullscreen: false;
    fake-transparency: false;
    dpi: -1;
    threads: 0;
    scrollbar-width: 8;
    scroll-method: 0;
    fake-background: "screenshot";
    window-format: "{w}    {c}   {t}";
    click-to-exit: true;
    show-match: true;
    theme: "Breeze-Dark";
    color-normal: "#2d3748, #e2e8f0, #2d3748, #5a67d8, #ffffff";
    color-urgent: "#2d3748, #e53e3e, #2d3748, #e53e3e, #ffffff";
    color-active: "#2d3748, #48bb78, #2d3748, #48bb78, #ffffff";
    color-window: "#2d3748, #5a67d8, #5a67d8";
    max-history: 25;
    combi-hide-mode-prefix: false;
    matching-negate-char: '-';
    cache-dir: "";
}
ROFICONF

# Alacritty terminal configuration
cat > "\$USER_HOME/.config/alacritty/alacritty.yml" <<'ALACRITTYCONF'
# Alacritty configuration
window:
  dimensions:
    columns: 100
    lines: 30
  padding:
    x: 8
    y: 8
  decorations: full
  startup_mode: Windowed

scrolling:
  history: 10000

font:
  normal:
    family: 'Noto Sans Mono'
    style: Regular
  bold:
    family: 'Noto Sans Mono'
    style: Bold
  italic:
    family: 'Noto Sans Mono'
    style: Italic
  size: 11.0

colors:
  primary:
    background: '0x2d3748'
    foreground: '0xe2e8f0'
  normal:
    black:   '0x2d3748'
    red:     '0xe53e3e'
    green:   '0x48bb78'
    yellow:  '0xecc94b'
    blue:    '0x5a67d8'
    magenta: '0x9f7aea'
    cyan:    '0x4fd1c7'
    white:   '0xe2e8f0'
  bright:
    black:   '0x4a5568'
    red:     '0xf56565'
    green:   '0x68d391'
    yellow:  '0xf6e05e'
    blue:    '0x7c3aed'
    magenta: '0xb794f6'
    cyan:    '0x63b3ed'
    white:   '0xffffff'

bell:
  animation: EaseOutExpo
  duration: 0

mouse:
  hide_when_typing: false

cursor:
  style: Block
  unfocused_hollow: true

live_config_reload: true

shell:
  program: /bin/bash
ALACRITTYCONF

# copy a default wallpaper and theme assets
mkdir -p /usr/share/backgrounds/arch-custom

# Check if user provided wallpaper exists
WALLPAPER_SOURCE="/tmp/arch-installer-wallpaper/default.jpg"
if [ -f "\$WALLPAPER_SOURCE" ]; then
  cp "\$WALLPAPER_SOURCE" /usr/share/backgrounds/arch-custom/default.jpg
  echo "Using provided wallpaper: default.jpg"
else
  # No wallpaper file created - let the fallback mechanism handle it with solid colors
  true
fi

# Create launcher script for tint2 panel
mkdir -p "\$USER_HOME/.config/tint2"
cat > "\$USER_HOME/.config/tint2/launcher.sh" <<'LAUNCHER'
#!/bin/bash
# Modern application launcher for tint2 panel
rofi -show drun
LAUNCHER
chmod +x "\$USER_HOME/.config/tint2/launcher.sh"

# Create polished dunst notification configuration
mkdir -p "\$USER_HOME/.config/dunst"
cat > "\$USER_HOME/.config/dunst/dunstrc" <<'DUNSTCONF'
[global]
    monitor = 0
    follow = mouse
    geometry = "350x5-15+49"
    indicate_hidden = yes
    shrink = no
    transparency = 10
    notification_height = 0
    separator_height = 2
    padding = 12
    horizontal_padding = 12
    frame_width = 1
    frame_color = "#5a67d8"
    separator_color = frame
    sort = yes
    idle_threshold = 120
    font = Noto Sans 10
    line_height = 0
    markup = full
    format = "<b>%s</b>\\n%b"
    alignment = left
    vertical_alignment = center
    show_age_threshold = 60
    word_wrap = yes
    ellipsize = middle
    ignore_newline = no
    stack_duplicates = true
    hide_duplicate_count = false
    show_indicators = yes
    icon_position = left
    min_icon_size = 32
    max_icon_size = 48
    icon_path = /usr/share/icons/Papirus-Dark/16x16/status/:/usr/share/icons/Papirus-Dark/16x16/devices/:/usr/share/icons/Papirus-Dark/16x16/apps/
    sticky_history = yes
    history_length = 20
    dmenu = rofi -dmenu -p dunst:
    browser = xdg-open
    always_run_script = true
    title = Dunst
    class = Dunst
    startup_notification = false
    verbosity = mesg
    corner_radius = 4
    ignore_dbusclose = false
    force_xinerama = false
    mouse_left_click = close_current
    mouse_middle_click = do_action, close_current
    mouse_right_click = close_all

[experimental]
    per_monitor_dpi = false

[urgency_low]
    background = "#2d3748"
    foreground = "#e2e8f0"
    timeout = 10

[urgency_normal]
    background = "#2d3748"
    foreground = "#e2e8f0"
    timeout = 10

[urgency_critical]
    background = "#e53e3e"
    foreground = "#ffffff"
    frame_color = "#ff6b6b"
    timeout = 0

[shortcuts]
    close = ctrl+space
    close_all = ctrl+shift+space
    history = ctrl+grave
    context = ctrl+shift+period
DUNSTCONF

# Set ownership for all user configuration files
chown -R ${USERNAME}:${USERNAME} "\$USER_HOME/.config"
chown -R ${USERNAME}:${USERNAME} "\$USER_HOME/.icons"
chown ${USERNAME}:${USERNAME} "\$USER_HOME/.gtkrc-2.0"

# Create .bashrc additions for theme environment variables
cat >> "\$USER_HOME/.bashrc" <<'BASHTHEME'

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
chown ${USERNAME}:${USERNAME} "\$USER_HOME/.bashrc"

# Create user directories for better UX
mkdir -p "\$USER_HOME/Pictures" "\$USER_HOME/Documents" "\$USER_HOME/Downloads"
mkdir -p "\$USER_HOME/Desktop" "\$USER_HOME/Music" "\$USER_HOME/Videos"
chown -R ${USERNAME}:${USERNAME} "\$USER_HOME/Pictures" "\$USER_HOME/Documents" "\$USER_HOME/Downloads"
chown -R ${USERNAME}:${USERNAME} "\$USER_HOME/Desktop" "\$USER_HOME/Music" "\$USER_HOME/Videos"

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
