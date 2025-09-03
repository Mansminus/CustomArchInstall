# Custom Arch Linux Installer

A guided TUI installer for Arch Linux that creates a beautiful, polished desktop experience with zero bloat.

## ✨ Features

### 🖥️ **Desktop Experience**
- **Multiple Window Managers:** Openbox (floating), i3 (tiling), dwm (minimal)
- **Beautiful Theming:** Arc-Dark GTK theme + Papirus-Dark icons + Breeze cursors
- **Custom Openbox Themes:** Choose between "Raven" (green accents) or "Triste" (red accents)
- **Professional UI:** Polished panels, notifications, and system tray

### 🎮 **Gaming Ready**
- **Gaming Detection:** Automatic gaming package installation when requested
- **Optimized Performance:** CPU governor and system optimizations for gaming
- **Gaming Stack:** Steam, Lutris, MangoHUD, GameMode (≥2GB RAM)
- **Lightweight Browser:** Smart browser selection to minimize gaming impact

### 🛠️ **Essential Applications**
- **Browser:** Firefox or Falkon (resource-conscious selection)
- **File Manager:** Thunar with archive plugin support
- **Media Tools:** VLC player, GPicView image viewer, MTpaint editor
- **Office Tools:** Evince PDF reader, Galculator
- **System Utilities:** GParted, Baobab disk analyzer, System Monitor
- **Productivity:** Flameshot screenshots, Clipit clipboard, Bluetooth manager

### ⚙️ **Complete System**
- **Audio:** Modern PipeWire audio stack
- **Networking:** NetworkManager with GUI applet
- **Printing:** Full CUPS printer support
- **Bluetooth:** Complete Bluetooth stack with GUI
- **Auto-mounting:** USB drives and phone support
- **Security:** UFW firewall pre-configured
- **Performance:** SSD TRIM support, zram for low-memory systems

## 🚀 Installation

### Prerequisites
- Boot from official Arch Linux ISO
- Connect to internet (ethernet auto, or use `iwctl` for WiFi)
- UEFI or BIOS systems supported

### Quick Install
```bash
# Download the installer directly
curl -O https://raw.githubusercontent.com/Mansminus/CustomArchInstall/main/install.sh

# Make it executable and run
chmod +x install.sh
sudo ./install.sh
```

### Alternative Download
```bash
# Using wget instead of curl
wget https://raw.githubusercontent.com/Mansminus/CustomArchInstall/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

### New Structure (Configs externalized)
- The installer now sources configuration templates from `configs/` instead of embedding them in `install.sh`.
- If you clone the repo, the script will copy `configs/` into the target and render them via envsubst.
- If you only download `install.sh`, it will fetch the repository archive at runtime to obtain `configs/`.

Key locations used during install:
- System templates: `/tmp/installer/configs/system/...`
- User templates: `/tmp/installer/configs/user/...`


## 🎯 What You Get

### **Minimal but Complete**
- **Zero Bloat:** Only essential packages, no unnecessary software
- **Full Functionality:** Everything works out of the box
- **User-Friendly:** Designed for users who don't want to use command line
- **Gaming Optimized:** Minimal OS impact on game performance

### **Professional Appearance**
- **Consistent Theming:** All applications follow the same dark theme
- **Modern UI:** Beautiful panels, notifications, and window decorations
- **Smart Layouts:** Professional positioning and sizing
- **Quality Applications:** Only polished, well-maintained software

### **Complete Desktop**
- **Printing Works:** Full CUPS setup with GUI configuration
- **Bluetooth Works:** Complete stack with user-friendly manager
- **USB Works:** Automatic mounting of drives and devices
- **Audio Works:** Modern PipeWire with volume controls
- **Network Works:** WiFi and ethernet with GUI management

## 🎮 Gaming Features

When you select "Gaming" during installation:
- **Steam** - Full Steam client with compatibility layers
- **Lutris** - Open gaming platform for Epic, GOG, etc.
- **MangoHUD** - Gaming performance overlay and monitoring
- **GameMode** - Automatic game performance optimization
- **Performance CPU Governor** - Maximum performance during gaming
- **Lightweight Browser** - Minimal system resource usage

## 🖥️ Desktop Environments

### **Openbox (Recommended)**
- Lightweight floating window manager
- Beautiful custom themes (Raven or Triste)
- Full panel with system tray
- Right-click application menu
- Keyboard shortcuts pre-configured

### **i3 (Power Users)**
- Tiling window manager
- Keyboard-centric workflow
- Status bar with system information
- Workspace management

### **dwm (Minimalists)**
- Ultra-minimal tiling WM
- Extremely low resource usage
- Source-based (falls back to i3)

## 🛠️ Customization

### **Themes**
- GTK themes can be changed via `lxappearance`
- Icon themes can be switched in the same tool
- Openbox themes are in `~/.themes/`
- Qt applications use `qt5ct` for theming

### **Wallpapers (Optional)**
- **Not Required:** The installer works perfectly without any wallpaper
- **Optional:** If desired, download any wallpaper as `default.jpg` and place it with the script
- **Sources:** Unsplash, Pixabay, or any image you like (1920x1080+ recommended)
- **Fallback:** Beautiful theme-matching solid colors (Raven=dark green, Triste=dark red)

### **User Aliases**
The installer creates helpful command aliases:
```bash
apps          # Open application launcher
screenshot    # Take screenshot with GUI
files         # Open file manager
calc          # Open calculator
bluetooth     # Open Bluetooth manager
lock          # Lock screen
update-system # Update all packages
```

## 🔧 Technical Details

### **Package Selection**
- **Base:** Essential Arch base system with development tools
- **Graphics:** Mesa drivers with Vulkan support
- **Audio:** PipeWire replacing PulseAudio
- **Network:** NetworkManager for reliability
- **Security:** UFW firewall enabled by default

### **System Services**
Auto-enabled services:
- NetworkManager (networking)
- systemd-timesyncd (time sync)  
- cups (printing)
- bluetooth (Bluetooth support)
- udisks2 (auto-mounting)
- fstrim.timer (SSD optimization)
- cpupower (CPU governor)

### **Performance Optimizations**
- `noatime` filesystem mounts for better I/O
- zram compression for systems with <2GB RAM
- Performance CPU governor for gaming systems
- Automatic SSD TRIM scheduling

## 📝 License

This installer is provided as-is for educational and personal use. The installed system uses standard Arch Linux packages under their respective licenses.

## 🤝 Contributing

Feel free to submit issues or pull requests to improve the installer.

---

**Enjoy your custom Arch Linux desktop!** 🎉

*The installer creates a complete, polished desktop that works like a commercial Linux distribution while maintaining the flexibility and power of Arch Linux.*
