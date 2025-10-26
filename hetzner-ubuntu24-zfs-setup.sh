#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Ubuntu 24 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info

set -euo pipefail

# ---- Configuration ----
# These will be set by user input
SYSTEM_HOSTNAME=""
ROOT_PASSWORD=""
ZFS_POOL=""
UBUNTU_CODENAME="noble"   # Ubuntu 24.04
TARGET="/mnt/ubuntu"

ZBM_BIOS_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.tar.gz"
ZBM_EFI_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.EFI"

MAIN_BOOT="/main_boot"

# Hetzner mirrors
MIRROR_SITE="https://mirror.hetzner.com"
MIRROR_MAIN="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME} main restricted universe multiverse"
MIRROR_UPDATES="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME}-updates main restricted universe multiverse"
MIRROR_BACKPORTS="deb ${MIRROR_SITE}/ubuntu/packages ${UBUNTU_CODENAME}-backports main restricted universe multiverse"
MIRROR_SECURITY="deb ${MIRROR_SITE}/ubuntu/security ${UBUNTU_CODENAME}-security main restricted universe multiverse"

# Global variables
INSTALL_DISK=""
EFI_MODE=false
BOOT_LABEL=""
BOOT_TYPE=""
BOOT_PART=""
ZFS_PART=""

# ---- User Input Functions ----
function setup_whiptail_colors {
    # Green text on black background - classic terminal theme
    export NEWT_COLORS='
    root=green,black
    window=green,black
    shadow=green,black
    border=green,black
    title=green,black
    textbox=green,black
    button=black,green
    listbox=green,black
    actlistbox=black,green
    actsellistbox=black,green
    checkbox=green,black
    actcheckbox=black,green
    entry=green,black
    label=green,black
    '
}

function check_whiptail {
    if ! command -v whiptail &> /dev/null; then
        echo "Installing whiptail..."
        apt update
        apt install -y whiptail
    fi
    setup_whiptail_colors
}


function get_hostname {
    while true; do
        SYSTEM_HOSTNAME=$(whiptail \
            --title "System Hostname" \
            --inputbox "Enter the hostname for the new system:" \
            10 60 "zfs-ubuntu" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Validate hostname
        if [[ "$SYSTEM_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ${#SYSTEM_HOSTNAME} -le 63 ]]; then
            break
        else
            whiptail \
                --title "Invalid Hostname" \
                --msgbox "Invalid hostname. Please use only letters, numbers, and hyphens. Must start and end with alphanumeric character. Maximum 63 characters." \
                12 60
        fi
    done
}

function get_zfs_pool_name {
    while true; do
        ZFS_POOL=$(whiptail \
            --title "ZFS Pool Name" \
            --inputbox "Enter the name for the ZFS pool:" \
            10 60 "rpool" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Validate ZFS pool name
        if [[ "$ZFS_POOL" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] && [[ ${#ZFS_POOL} -le 255 ]]; then
            break
        else
            whiptail \
                --title "Invalid Pool Name" \
                --msgbox "Invalid ZFS pool name. Must start with a letter and contain only letters, numbers, hyphens, and underscores. Maximum 255 characters." \
                12 60
        fi
    done
}

function get_root_password {
    while true; do
        # Get first password input
        local password1
        local password2
        
        password1=$(whiptail \
            --title "Root Password" \
            --passwordbox "Enter root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Get password confirmation
        password2=$(whiptail \
            --title "Confirm Root Password" \
            --passwordbox "Confirm root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            whiptail --title "Cancelled" --msgbox "Installation cancelled by user." 10 50
            exit 1
        fi
        
        # Check if passwords match
        if [ "$password1" = "$password2" ]; then
            if [ -n "$password1" ]; then
                ROOT_PASSWORD="$password1"
                break
            else
                whiptail \
                    --title "Empty Password" \
                    --msgbox "Password cannot be empty. Please enter a password." \
                    10 50
            fi
        else
            whiptail \
                --title "Password Mismatch" \
                --msgbox "Passwords do not match. Please try again." \
                10 50
        fi
    done
}

function show_summary_and_confirm {
    local summary="Please review the installation settings:

Hostname: $SYSTEM_HOSTNAME
ZFS Pool: $ZFS_POOL
Ubuntu Version: $UBUNTU_CODENAME (24.04)
Target: $TARGET
Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")
Install Disk: $INSTALL_DISK

*** WARNING: This will DESTROY ALL DATA on $INSTALL_DISK! ***

Do you want to continue with the installation?"
    
    if whiptail \
        --title " Installation Summary " \
        --yesno "$summary" \
        18 60; then
        # User confirmed - just continue silently
        echo "User confirmed installation. Starting now..."
    else
        echo "Installation cancelled by user."
        exit 1
    fi
}

function get_user_input {
    echo "======= Gathering Installation Parameters =========="
    check_whiptail
    
    # Show welcome message
    whiptail \
        --title "ZFS Ubuntu Installer" \
        --msgbox "Welcome to the ZFS Ubuntu Installer for Hetzner Cloud.\n\nThis script will install Ubuntu 24.04 with ZFS root on your server." \
        12 60
    
    # Get user inputs
    get_hostname
    get_zfs_pool_name
    get_root_password
}

# ---- System Detection Functions ----
function detect_efi {
    echo "======= Detecting EFI support =========="
    
    if [ -d /sys/firmware/efi ]; then
        echo "✓ EFI firmware detected"
        EFI_MODE=true
        BOOT_LABEL="EFI"
        BOOT_TYPE="ef00"
    else
        echo "✓ Legacy BIOS mode detected"
        EFI_MODE=false
        BOOT_LABEL="boot"
        BOOT_TYPE="8300"
    fi
}

function find_install_disk {
    echo "======= Finding install disk =========="
    
    local candidate_disks=()
    
    # Use lsblk to find all unmounted, writable disks
    while IFS= read -r disk; do
        [[ -n "$disk" ]] && candidate_disks+=("$disk")
    done < <(lsblk -npo NAME,TYPE,RO,MOUNTPOINT | awk '
        $2 == "disk" && $3 == "0" && $4 == "" {print $1}
    ')
    
    if [[ ${#candidate_disks[@]} -eq 0 ]]; then
        echo "No suitable installation disks found" >&2
        echo "Looking for: unmounted, writable disks without partitions in use" >&2
        exit 1
    fi
    
    INSTALL_DISK="${candidate_disks[0]}"
    echo "Using installation disk: $INSTALL_DISK"
    
    # Show all available disks for verification
    echo "All available disks:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,RO | grep -v loop
}

# ---- Rescue System Preparation Functions ----
function remove_unused_kernels {
    echo "=========== Removing unused kernels in rescue system =========="
    for kver in $(find /lib/modules/* -maxdepth 0 -type d \
                    | grep -v "$(uname -r)" \
                    | cut -s -d "/" -f 4); do

        for pkg in "linux-headers-$kver" "linux-image-$kver"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                echo "Purging $pkg ..."
                apt purge --yes "$pkg"
            else
                echo "Package $pkg not installed, skipping."
            fi
        done
    done
}

function install_zfs_on_rescue_system {
    echo "======= Installing ZFS on rescue system =========="
    echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections
    # Enable Hetzner bookworm-backports
    sed -i 's/^# deb http:\/\/mirror.hetzner.com\/debian\/packages bookworm-backports/deb http:\/\/mirror.hetzner.com\/debian\/packages bookworm-backports/' /etc/apt/sources.list
    apt update
    apt -t bookworm-backports install -y zfsutils-linux
}

# ---- Disk Partitioning Functions ----
function partition_disk {
    echo "======= Partitioning disk =========="
    sgdisk -Z "$INSTALL_DISK"  
    
    if [ "$EFI_MODE" = true ]; then
        echo "Creating EFI partition layout"
        # EFI System Partition (ESP) - 64MB is plenty for ZFSBootMenu
        sgdisk -n1:1M:+128M -t1:ef00 -c1:"EFI" "$INSTALL_DISK"
        # ZFS partition
        sgdisk -n2:0:0   -t2:bf00 -c2:"zfs"  "$INSTALL_DISK"
    else
        echo "Creating BIOS partition layout"
        # /boot partition - 64MB is also sufficient for BIOS ZFSBootMenu
        sgdisk -n1:1M:+128M -t1:8300 -c1:"boot" "$INSTALL_DISK"
        # ZFS partition
        sgdisk -n2:0:0   -t2:bf00 -c2:"zfs"  "$INSTALL_DISK"
        # Set legacy BIOS bootable flag
        sgdisk -A 1:set:2 "$INSTALL_DISK"
    fi
    
    partprobe "$INSTALL_DISK" || true
    udevadm settle
    
    # Set partition variables based on mode
    if [ "$EFI_MODE" = true ]; then
        BOOT_PART="$(blkid -t PARTLABEL='EFI' -o device)"
        ZFS_PART="$(blkid -t PARTLABEL='zfs' -o device)"
        # Format ESP as FAT32
        mkfs.fat -F 32 -n EFI "$BOOT_PART"
    else
        BOOT_PART="$(blkid -t PARTLABEL='boot' -o device)"
        ZFS_PART="$(blkid -t PARTLABEL='zfs' -o device)"
        mkfs.ext4 -F -L boot "$BOOT_PART"
    fi
}

# ---- ZFS Pool and Dataset Functions ----
function create_zfs_pool {
    echo "======= Creating ZFS pool =========="
    # Clean up any existing ZFS binaries in PATH
    rm -f "$(which zfs)" 2>/dev/null || true
    rm -f "$(which zpool)" 2>/dev/null || true
    
    export PATH=/usr/sbin:$PATH
    modprobe zfs
    
    zpool create -f -o ashift=12 \
    -o cachefile="/etc/zfs/zpool.cache" \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O mountpoint=none \
    "$ZFS_POOL" "$ZFS_PART"

    zfs create -o mountpoint=none   "$ZFS_POOL/ROOT"
    zfs create -o mountpoint=legacy "$ZFS_POOL/ROOT/ubuntu"

    echo "======= Assigning $ZFS_POOL/ROOT/ubuntu dataset as bootable =========="
    zpool set bootfs="$ZFS_POOL/ROOT/ubuntu" "$ZFS_POOL"
    zpool set cachefile="/etc/zfs/zpool.cache" "$ZFS_POOL"
}

function create_additional_zfs_datasets {
    echo "======= Creating additional ZFS datasets with TEMPORARY mountpoints =========="
    
    # Ensure parent datasets are created first
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/ubuntu/var"
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/ubuntu/var/cache"
    
    # Create leaf datasets with temporary mountpoints under $TARGET
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/tmp" "$ZFS_POOL/ROOT/ubuntu/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/ubuntu/tmp"
    
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/var/tmp" "$ZFS_POOL/ROOT/ubuntu/var/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/ubuntu/var/tmp"
    
    zfs create -o mountpoint="$TARGET/var/log" "$ZFS_POOL/ROOT/ubuntu/var/log"    
    zfs set atime=off "$ZFS_POOL/ROOT/ubuntu/var/log"
    
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/var/cache/apt" "$ZFS_POOL/ROOT/ubuntu/var/cache/apt"    
    zfs set atime=off "$ZFS_POOL/ROOT/ubuntu/var/cache/apt"
    
    # Create home dataset separately
    zfs create -o mountpoint="$TARGET/home" "$ZFS_POOL/home"
    
    # Mount all datasets
    zfs mount -a
    
    # Set permissions on the actual ZFS datasets
    echo "Setting permissions on ZFS datasets..."
    chmod 1777 "$TARGET/tmp"
    chmod 1777 "$TARGET/var/tmp"
    echo "✓ Temp directory permissions set (1777)"
}

function set_final_mountpoints {
    echo "======= Setting final mountpoints =========="
    
    # Leaf datasets - actual system mountpoints
    zfs set mountpoint=/tmp "$ZFS_POOL/ROOT/ubuntu/tmp"
    zfs set mountpoint=/var/tmp "$ZFS_POOL/ROOT/ubuntu/var/tmp"
    zfs set mountpoint=/var/log "$ZFS_POOL/ROOT/ubuntu/var/log"
    zfs set mountpoint=/var/cache/apt "$ZFS_POOL/ROOT/ubuntu/var/cache/apt"
    
    # Home dataset - separate from OS
    zfs set mountpoint=/home "$ZFS_POOL/home"    
    echo ""
    echo "Detailed dataset listing:"
    zfs list -o name,mountpoint -r "$ZFS_POOL"
}

# ---- System Bootstrap Functions ----
function bootstrap_ubuntu_system {
    echo "======= Bootstrapping Ubuntu to temporary directory =========="
    local TEMP_STAGE=$(mktemp -d)
    echo "Created temporary staging directory: $TEMP_STAGE"
    
    # Cleanup function for temp directory
    cleanup_temp_stage() {
        if [ -d "$TEMP_STAGE" ]; then
            echo "Cleaning up temporary staging directory..."
            rm -rf "$TEMP_STAGE"
        fi
    }
    
    # Add trap to ensure cleanup on script exit
    trap cleanup_temp_stage EXIT
    
    # Add Hetzner Ubuntu mirror as trusted
    echo "deb [trusted=yes] http://mirror.hetzner.com/ubuntu/packages noble main" > /etc/apt/sources.list.d/ubuntu-temp.list

    # Update and download ubuntu-keyring without sandbox warning
    apt-get update
    apt-get -o APT::Sandbox::User=root download ubuntu-keyring

    # Verify download was successful
    if [ ! -f ubuntu-keyring*.deb ]; then
        echo "ERROR: Failed to download ubuntu-keyring package"
        exit 1
    fi

    # Extract the keyring
    dpkg-deb -x ubuntu-keyring*.deb /tmp/ubuntu-keyring-extract/
    mkdir -p /usr/share/keyrings
    cp /tmp/ubuntu-keyring-extract/usr/share/keyrings/ubuntu-archive-keyring.gpg /usr/share/keyrings/

    echo "✓ Downloaded and extracted ubuntu-keyring package"

    # Clean up - remove temporary repository and restore apt state
    rm -f /etc/apt/sources.list.d/ubuntu-temp.list
    apt update

    # Clean up downloaded package
    rm -f ubuntu-keyring*.deb

    apt install -y mmdebstrap

    mmdebstrap --variant=debootstrap \
      --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
      --include=systemd-resolved,locales,debconf-i18n,apt-utils,keyboard-configuration,console-setup,kbd,extlinux,initramfs-tools,zstd \
      "$UBUNTU_CODENAME" "$TEMP_STAGE" \
      "$MIRROR_MAIN" "$MIRROR_UPDATES" "$MIRROR_BACKPORTS" "$MIRROR_SECURITY"

    echo "======= Copying staged system to ZFS datasets =========="
    # Mount root dataset for copying
    mkdir -p "$TARGET"
    mount -t zfs "$ZFS_POOL/ROOT/ubuntu" "$TARGET"

    create_additional_zfs_datasets

    # Use rsync to copy the entire system (this will populate all datasets)
    echo "Copying staged system to ZFS datasets..."
    rsync -aAX "$TEMP_STAGE/" "$TARGET/"

    echo "Staged system copied successfully"
    echo "Source size: $(du -sh "$TEMP_STAGE")"
    echo "Target size: $(du -sh "$TARGET")"

    # Clean up temp directory
    cleanup_temp_stage
    trap - EXIT
}

function setup_chroot_environment {
    echo "======= Mounting virtual filesystems for chroot =========="
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sysfs "$TARGET/sys"
    mount -t tmpfs tmpfs "$TARGET/run"
    mount -t tmpfs tmpfs "$TARGET/tmp"
    mount --bind /dev "$TARGET/dev"
    mount --bind /dev/pts "$TARGET/dev/pts"

    configure_dns_resolution
}

function configure_dns_resolution {
    echo "======= Configuring DNS resolution =========="
    mkdir -p "$TARGET/run/systemd/resolve"
    
    if command -v resolvectl >/dev/null 2>&1; then
        echo "Getting DNS from resolvectl..."
        
        # First try Global DNS servers
        local DNS_SERVERS=$(resolvectl dns | awk '
            /^Global:/ { 
                for(i=2; i<=NF; i++) print $i 
            }
        ' | head -3)
        
        # If Global is empty, find first non-empty link
        if [ -z "$DNS_SERVERS" ]; then
            echo "No global DNS servers found, searching for first non-empty link..."
            DNS_SERVERS=$(resolvectl dns | awk '
                /^Link [0-9]+ / && NF > 3 {
                    for(i=4; i<=NF; i++) print $i  # Start from field 4 to skip the interface name
                    exit  # Stop after first non-empty link
                }
            ')
        fi
        
        if [ -n "$DNS_SERVERS" ]; then
            # Create resolv.conf with the DNS servers
            echo "$DNS_SERVERS" | while read -r dns; do
                echo "nameserver $dns"
            done > "$TARGET/run/systemd/resolve/stub-resolv.conf"
            echo "Using DNS servers: $(echo "$DNS_SERVERS" | tr '\n' ' ')"
        else
            echo "ERROR: No DNS servers found in resolvectl output"
            echo "resolvectl dns output:"
            resolvectl dns
            echo "Cannot continue without DNS configuration"
            exit 1
        fi
    else
        echo "ERROR: resolvectl command not found"
        echo "Cannot configure DNS without resolvectl"
        exit 1
    fi
}

# ---- System Configuration Functions ----
function configure_basic_system {
    echo "======= Configuring basic system settings =========="
    chroot "$TARGET" /bin/bash <<EOF
set -euo pipefail

# Set hostname from variable
echo "$SYSTEM_HOSTNAME" > /etc/hostname

# Configure timezone (Vienna)
echo "Europe/Vienna" > /etc/timezone
ln -sf /usr/share/zoneinfo/Europe/Vienna /etc/localtime

# Generate locales
cat > /etc/locale.gen <<'LOCALES'
en_US.UTF-8 UTF-8
de_AT.UTF-8 UTF-8
fr_FR.UTF-8 UTF-8  
ru_RU.UTF-8 UTF-8
LOCALES

locale-gen

# Set default locale
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Configure keyboard for German and US with Alt+Shift toggle
cat > /etc/default/keyboard <<'KEYBOARD'
# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="de,ru"
XKBVARIANT=","
XKBOPTIONS="grp:ctrl_shift_toggle"

BACKSPACE="guess"
KEYBOARD

# Apply keyboard configuration to console
setupcon --force

# Update /etc/hosts with the hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $SYSTEM_HOSTNAME" >> /etc/hosts
echo "::1 localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1 ip6-allnodes" >> /etc/hosts
echo "ff02::2 ip6-allrouters" >> /etc/hosts

# Set proper permissions for ZFS datasets
chmod 1777 /tmp
chmod 1777 /var/tmp
EOF

    echo "======= Configuration Summary ======="
    chroot "$TARGET" /bin/bash <<'EOF'
echo "Hostname: $(cat /etc/hostname)"
echo "Timezone: $(cat /etc/timezone)"
echo "Current time: $(date)"
echo "Default locale: $(grep LANG /etc/default/locale)"
echo "Available locales:"
locale -a | grep -E "(en_US|de_AT|fr_FR|ru_RU)"
echo "Keyboard layout: $(grep XKBLAYOUT /etc/default/keyboard)"
EOF
}

function install_system_packages {
    echo "======= Installing ZFS and essential packages in chroot =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
# Update package lists
apt update

# Install generic kernel (creates files in ZFS dataset /boot)
apt install -y --no-install-recommends linux-image-generic linux-headers-generic

# Install ZFS utilities and aux packages

echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

apt install -y zfs-dkms zfsutils-linux zfs-initramfs software-properties-common bash curl nano htop net-tools ssh

# Ensure ZFS module is included in initramfs
echo "zfs" >> /etc/initramfs-tools/modules

# Generate initramfs with ZFS support
update-initramfs -u -k all

# Verify kernel installation
echo "Installed kernel packages:"
dpkg -l | grep linux-image
echo "Kernel version:"
ls /lib/modules/
echo "Kernel files in ZFS dataset:"
ls -la /boot/vmlinuz* /boot/initrd.img* 2>/dev/null || echo "No kernel files found"
EOF
}

function configure_ssh {
    echo "======= Setting up OpenSSH =========="
    mkdir -p "$TARGET/root/.ssh/"
    cp /root/.ssh/authorized_keys "$TARGET/root/.ssh/authorized_keys"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' "$TARGET/etc/ssh/sshd_config"
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' "$TARGET/etc/ssh/sshd_config"

    chroot "$TARGET" /bin/bash <<'EOF'
rm /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server -f noninteractive
EOF
}

function set_root_credentials {
    echo "======= Setting root password =========="
    chroot "$TARGET" /bin/bash -c "echo root:$(printf "%q" "$ROOT_PASSWORD") | chpasswd"

    echo "============ Setting up root prompt ============"
    cat > "$TARGET/root/.bashrc" <<CONF
export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
umask 022
export LS_OPTIONS='--color=auto -h'
eval "\$(dircolors)"
CONF
}

# ---- Bootloader Functions ----
function setup_efi_boot {
    echo "======= Setting up EFI boot =========="
    
    # Mount EFI System Partition
    mkdir -p "$MAIN_BOOT"
    mount "$BOOT_PART" "$MAIN_BOOT"
    
    # Create EFI directory structure    
    mkdir -p "$MAIN_BOOT/EFI/Boot"
    
    # Download ZFSBootMenu EFI binary
    echo "Downloading ZFSBootMenu EFI binary from: $ZBM_EFI_URL"
    curl -L "$ZBM_EFI_URL" -o "$MAIN_BOOT/EFI/Boot/bootx64.efi"    
}

function setup_bios_boot {
    echo "======= Setting up BIOS boot =========="
    
    # Mount boot partition
    mkdir -p "$MAIN_BOOT"
    mount "$BOOT_PART" "$MAIN_BOOT"
    
    # Install extlinux in rescue system if needed
    if ! command -v extlinux &> /dev/null; then
        echo "Installing extlinux in rescue system..."
        apt update
        apt install -y extlinux
    fi
    
    # Install extlinux
    extlinux --install "$MAIN_BOOT"
    
    # Create extlinux configuration
    cat > "$MAIN_BOOT/extlinux.conf" << 'EOF'
DEFAULT zfsbootmenu
PROMPT 0
TIMEOUT 0

LABEL zfsbootmenu
    LINUX /zfsbootmenu/vmlinuz-bootmenu
    INITRD /zfsbootmenu/initramfs-bootmenu.img
    APPEND ro quiet
EOF

    echo "Generated extlinux.conf:"
    cat "$MAIN_BOOT/extlinux.conf"
    
    # Download and install ZFSBootMenu for BIOS
    local TEMP_ZBM=$(mktemp -d)
    echo "Downloading ZFSBootMenu for BIOS from: $ZBM_BIOS_URL"
    curl -L "$ZBM_BIOS_URL" -o "$TEMP_ZBM/zbm.tar.gz"
    tar -xz -C "$TEMP_ZBM" -f "$TEMP_ZBM/zbm.tar.gz" --strip-components=1
    
    # Copy ZFSBootMenu to boot partition
    mkdir -p "$MAIN_BOOT/zfsbootmenu"
    cp "$TEMP_ZBM"/vmlinuz* "$MAIN_BOOT/zfsbootmenu/"
    cp "$TEMP_ZBM"/initramfs* "$MAIN_BOOT/zfsbootmenu/"
    
    # Clean up
    rm -rf "$TEMP_ZBM"
    
    echo "ZFSBootMenu files copied to boot partition:"
    ls -la "$MAIN_BOOT/zfsbootmenu/"
    
    # Install MBR and set boot flag
    dd bs=440 conv=notrunc count=1 if="$TARGET/usr/lib/EXTLINUX/gptmbr.bin" of="$INSTALL_DISK"
    parted "$INSTALL_DISK" set 1 boot on
    
    echo "BIOS boot setup complete"
}

function configure_bootloader {
    echo "======= Setting up boot based on firmware type =========="
    if [ "$EFI_MODE" = true ]; then
        setup_efi_boot
    else
        setup_bios_boot
    fi

    echo "======= Configuring ZFSBootMenu for auto-detection =========="
    zfs set org.zfsbootmenu:commandline="ro quiet" "$ZFS_POOL/ROOT/ubuntu"

    echo "Boot configuration:"
    zfs get org.zfsbootmenu:commandline "$ZFS_POOL/ROOT/ubuntu"
}

# ---- System Services Functions ----
function configure_system_services {
    echo "======= Configuring ZFS cachefile in chrooted system =========="
    mkdir -p "$TARGET/etc/zfs"
    cp /etc/zfs/zpool.cache "$TARGET/etc/zfs/zpool.cache"

    echo "Cachefile status:"
    zpool get cachefile "$ZFS_POOL"
    ls -la "$TARGET/etc/zfs/zpool.cache" && echo "✓ Cachefile ready" || echo "✗ Cachefile failed"

    echo "======= Enabling essential system services =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail

systemctl enable systemd-resolved
systemctl enable systemd-timesyncd

systemctl enable zfs-import-cache
systemctl enable zfs-mount

systemctl enable ssh
systemctl enable apt-daily.timer

echo "Enabled services:"
systemctl list-unit-files | grep enabled
EOF
}

function configure_networking {
    echo "======= Configuring Netplan for Hetzner Cloud =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
# Create Netplan configuration that matches all non-loopback interfaces
cat > /etc/netplan/01-hetzner.yaml <<'EOL'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-interfaces:
      match:
        name: "!lo"
      dhcp4: true
      dhcp6: true
      dhcp4-overrides:
        use-dns: true
        use-hostname: true
        use-domains: true
        route-metric: 100
      dhcp6-overrides:
        use-dns: true
        use-hostname: true
        use-domains: true
        route-metric: 100
      critical: true
EOL

# Set proper permissions - Netplan requires strict permissions (600)
chmod 600 /etc/netplan/01-hetzner.yaml
chown root:root /etc/netplan/01-hetzner.yaml

# Apply the Netplan configuration
netplan generate
echo "Netplan configuration created for all interfaces"
EOF
}

# ---- Cleanup and Finalization Functions ----
function unmount_all_datasets_and_partitions {
    echo "======= Unmounting all datasets =========="
    
    # First, unmount all auto-mounted ZFS datasets (tmp, var/tmp, var/log, etc.)
    echo "Unmounting auto-mounted ZFS datasets..."
    zfs umount -a 2>/dev/null || true
    
    # Manually unmount the root legacy dataset from $TARGET
    if mountpoint -q "$TARGET"; then
        echo "Unmounting root dataset from $TARGET"
        umount "$TARGET" 2>/dev/null || true
    fi
    
    # Manually unmount boot partition if mounted
    if mountpoint -q "$MAIN_BOOT"; then
        echo "Unmounting boot partition from $MAIN_BOOT"
        umount "$MAIN_BOOT" 2>/dev/null || true
    fi
    
    # Wait for unmounts to complete
    sleep 1
    
    # Force unmount any stubborn datasets
    if zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -q "yes"; then
        echo "Forcing unmount of remaining ZFS datasets..."
        zfs umount -a -f 2>/dev/null || true
    fi
    
    # Final verification
    local mounted_count=0
    mounted_count=$(zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -c "yes" || true)
    
    if [ "$mounted_count" -gt 0 ]; then
        echo "WARNING: $mounted_count dataset(s) still mounted after unmount attempt:"
        zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep "yes" || true
    else
        echo "✓ All ZFS datasets successfully unmounted"
    fi
    
    # Verify $TARGET is unmounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted!"
        mount | grep "$TARGET" || true
    else
        echo "✓ $TARGET successfully unmounted"
    fi
    
    # Verify $MAIN_BOOT is unmounted
    if mountpoint -q "$MAIN_BOOT"; then
        echo "WARNING: $MAIN_BOOT is still mounted!"
        mount | grep "$MAIN_BOOT" || true
    else
        echo "✓ $MAIN_BOOT successfully unmounted"
    fi
}

function unmount_chroot_environment {
    echo "======= Unmounting virtual filesystems =========="
    # Unmount virtual filesystems first
    for dir in dev/pts dev tmp run sys proc; do
        if mountpoint -q "$TARGET/$dir"; then
            echo "Unmounting $TARGET/$dir"
            umount "$TARGET/$dir" 2>/dev/null || true
        fi
    done
}

function finalize_system_resolved {
    echo "======= Setting systemd-resolved configuration for final boot =========="
    # This must be done while $TARGET is still mounted
    mkdir -p "$TARGET/run/systemd/resolve"
    cat > "$TARGET/run/systemd/resolve/stub-resolv.conf" << 'EOF'
nameserver 127.0.0.53
options edns0 trust-ad
search .
EOF
    echo "✓ systemd-resolved configuration set"
}

function export_zfs_pool {
    echo "======= Exporting ZFS pool =========="
    zpool export "$ZFS_POOL" 2>/dev/null || true

    # Verify everything is unmounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted!"
        mount | grep "$TARGET"
    else
        echo "✓ All filesystems successfully unmounted"
    fi
}

function show_final_instructions {
    echo ""
    echo "=========================================="
    echo "  INSTALLATION COMPLETE! "
    echo "=========================================="
    echo ""
    echo "System Information:"
    echo "  Hostname: $SYSTEM_HOSTNAME"
    echo "  ZFS Pool: $ZFS_POOL"
    echo "  Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")"
    echo "  Ubuntu Version: $UBUNTU_CODENAME"
    echo "  Networking: systemd-networkd + systemd-resolved"    
    echo ""
    echo "=========================================="
    echo "Rebooting..."
}

# ---- Main Execution Function ----
function main {
    echo "Starting ZFS Ubuntu installation on Hetzner Cloud..."
    
    # Phase 0: User input
    get_user_input
    
    # Phase 1: System detection and preparation
    detect_efi
    find_install_disk
    
    # Show summary and get final confirmation
    show_summary_and_confirm
    
    remove_unused_kernels
    install_zfs_on_rescue_system
    
    # Phase 2: Disk partitioning and ZFS setup
    partition_disk
    create_zfs_pool
    
    # Phase 3: System bootstrap
    bootstrap_ubuntu_system
    setup_chroot_environment
    
    # Phase 4: System configuration
    configure_basic_system
    install_system_packages
    configure_ssh
    set_root_credentials
    configure_system_services
    configure_networking
    
    # Phase 5: Bootloader setup
    configure_bootloader
    
    # Phase 6: Cleanup and finalization
    unmount_chroot_environment
    finalize_system_resolved    
    unmount_all_datasets_and_partitions
    
    # Phase 7: Final mountpoints and export    
    set_final_mountpoints
    
    export_zfs_pool
    
    show_final_instructions

    reboot
}

# Execute main function
main "$@"