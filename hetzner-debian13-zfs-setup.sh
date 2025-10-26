#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Debian 13 with ZFS root on Hetzner VPS
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
SYSTEM_HOSTNAME=""
ROOT_PASSWORD=""
ZFS_POOL=""
DEBIAN_CODENAME="trixie"   # Debian 13
TARGET="/mnt/debian"

ZBM_BIOS_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.tar.gz"
ZBM_EFI_URL="https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-linux6.1.EFI"

MAIN_BOOT="/main_boot"

# Hetzner mirrors for Debian
MIRROR_SITE="https://mirror.hetzner.com"
MIRROR_MAIN="deb ${MIRROR_SITE}/debian/packages ${DEBIAN_CODENAME} main contrib non-free non-free-firmware"
MIRROR_UPDATES="deb ${MIRROR_SITE}/debian/packages ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware"
MIRROR_SECURITY="deb ${MIRROR_SITE}/debian/security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware"

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
            --title " System Hostname " \
            --inputbox "\nEnter the hostname for the new system:" \
            10 60 "zfs-debian" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Validate hostname
        if [[ "$SYSTEM_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]] && [[ ${#SYSTEM_HOSTNAME} -le 63 ]]; then
            break
        else
            whiptail \
                --title " Invalid Hostname " \
                --msgbox "Invalid hostname. Please use only letters, numbers, and hyphens. Must start and end with alphanumeric character. Maximum 63 characters." \
                12 60
        fi
    done
}

function get_zfs_pool_name {
    while true; do
        ZFS_POOL=$(whiptail \
            --title " ZFS Pool Name " \
            --inputbox "\nEnter the name for the ZFS pool:" \
            10 60 "rpool" \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Validate ZFS pool name
        if [[ "$ZFS_POOL" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] && [[ ${#ZFS_POOL} -le 255 ]]; then
            break
        else
            whiptail \
                --title " Invalid Pool Name " \
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
            --title " Root Password " \
            --passwordbox "\nEnter root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        local exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Get password confirmation
        password2=$(whiptail \
            --title " Confirm Root Password " \
            --passwordbox "\nConfirm root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3)
        
        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Installation cancelled by user."
            exit 1
        fi
        
        # Check if passwords match
        if [ "$password1" = "$password2" ]; then
            if [ -n "$password1" ]; then
                ROOT_PASSWORD="$password1"
                break
            else
                whiptail \
                    --title " Empty Password " \
                    --msgbox "Password cannot be empty. Please enter a password." \
                    10 50
            fi
        else
            whiptail \
                --title " Password Mismatch " \
                --msgbox "Passwords do not match. Please try again." \
                10 50
        fi
    done
}

function show_summary_and_confirm {
    local summary="Please review the installation settings:

Hostname: $SYSTEM_HOSTNAME
ZFS Pool: $ZFS_POOL
Debian Version: $DEBIAN_CODENAME (13)
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
        --title " ZFS Debian Installer " \
        --msgbox "Welcome to the ZFS Debian Installer for Hetzner Cloud.\n\nThis script will install Debian 13 with ZFS root on your server." \
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
    # Enable backports for newer ZFS version
    echo "deb http://mirror.hetzner.com/debian/packages bookworm-backports main contrib" > /etc/apt/sources.list.d/backports.list
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
    zfs create -o mountpoint=legacy "$ZFS_POOL/ROOT/debian"

    echo "======= Assigning $ZFS_POOL/ROOT/debian dataset as bootable =========="
    zpool set bootfs="$ZFS_POOL/ROOT/debian" "$ZFS_POOL"
    zpool set cachefile="/etc/zfs/zpool.cache" "$ZFS_POOL"
}

function create_additional_zfs_datasets {
    echo "======= Creating additional ZFS datasets with TEMPORARY mountpoints =========="
    
    # Ensure parent datasets are created first
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/debian/var"
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/debian/var/cache"
    
    # Create leaf datasets with temporary mountpoints under $TARGET
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/tmp" "$ZFS_POOL/ROOT/debian/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/debian/tmp"
    
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/var/tmp" "$ZFS_POOL/ROOT/debian/var/tmp"
    zfs set devices=off "$ZFS_POOL/ROOT/debian/var/tmp"
    
    zfs create -o mountpoint="$TARGET/var/log" "$ZFS_POOL/ROOT/debian/var/log"    
    zfs set atime=off "$ZFS_POOL/ROOT/debian/var/log"
    
    zfs create -o com.sun:auto-snapshot=false -o mountpoint="$TARGET/var/cache/apt" "$ZFS_POOL/ROOT/debian/var/cache/apt"    
    zfs set atime=off "$ZFS_POOL/ROOT/debian/var/cache/apt"
    
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
    zfs set mountpoint=/tmp "$ZFS_POOL/ROOT/debian/tmp"
    zfs set mountpoint=/var/tmp "$ZFS_POOL/ROOT/debian/var/tmp"
    zfs set mountpoint=/var/log "$ZFS_POOL/ROOT/debian/var/log"
    zfs set mountpoint=/var/cache/apt "$ZFS_POOL/ROOT/debian/var/cache/apt"
    
    # Home dataset - separate from OS
    zfs set mountpoint=/home "$ZFS_POOL/home"    
    echo ""
    echo "Detailed dataset listing:"
    zfs list -o name,mountpoint -r "$ZFS_POOL"
}

# ---- System Bootstrap Functions ----
function bootstrap_debian_system {
    echo "======= Bootstrapping Debian to temporary directory =========="
    
    # Install debootstrap if not available
    if ! command -v debootstrap &> /dev/null; then
        echo "Installing debootstrap..."
        apt update
        apt install -y debootstrap
    fi

    #echo "======= Copying staged system to ZFS datasets =========="
    # Mount root dataset for copying
    mkdir -p "$TARGET"
    mount -t zfs "$ZFS_POOL/ROOT/debian" "$TARGET"

    create_additional_zfs_datasets

    # Bootstrap Debian 13 (Trixie) - include dbus to satisfy systemd-resolved dependency
    debootstrap \
        --components=main,contrib,non-free,non-free-firmware \
        --include=initramfs-tools,dbus,locales,debconf-i18n,apt-utils,keyboard-configuration,console-setup,kbd,zstd,systemd-resolved,systemd-timesyncd \
        "$DEBIAN_CODENAME" \
        "$TARGET" \
        "$MIRROR_SITE/debian/packages"    

}

function setup_chroot_environment {
    echo "======= Mounting virtual filesystems for chroot =========="
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sysfs "$TARGET/sys"
    
    # Only mount specific tmpfs directories, not the entire /run
    mkdir -p "$TARGET/run/lock" "$TARGET/run/shm"
    mount -t tmpfs tmpfs "$TARGET/run/lock"
    mount -t tmpfs tmpfs "$TARGET/run/shm"
    mount -t tmpfs tmpfs "$TARGET/tmp"
    
    mount --bind /dev "$TARGET/dev"
    mount --bind /dev/pts "$TARGET/dev/pts"
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

# Configure sources.list for Debian 13
cat > /etc/apt/sources.list <<'SOURCES'
deb https://mirror.hetzner.com/debian/packages trixie main contrib non-free non-free-firmware
deb https://mirror.hetzner.com/debian/packages trixie-updates main contrib non-free non-free-firmware
deb https://mirror.hetzner.com/debian/security trixie-security main contrib non-free non-free-firmware
deb https://mirror.hetzner.com/debian/packages trixie-backports main contrib non-free non-free-firmware
SOURCES

# Update package lists
apt update

# Install kernel
apt install -y --no-install-recommends linux-image-cloud-amd64 linux-headers-cloud-amd64

# Install essential packages
apt install -y curl nano htop net-tools ssh \
    apt-transport-https ca-certificates gnupg dirmngr \
    firmware-linux-free apparmor

echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections

apt install -y -t trixie-backports zfsutils-linux zfs-initramfs zfs-dkms

# Get the actual kernel version installed in the chroot
KERNEL_VERSION=$(ls /lib/modules/ | head -n1)
echo "Detected kernel version: $KERNEL_VERSION"

# Verify ZFS module is available in the chroot filesystem
echo "=== Verifying ZFS module in chroot ==="
if find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f | grep -q .; then
    echo "✓ ZFS module files found in /lib/modules/$KERNEL_VERSION/"
    find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f
else
    echo "✗ ZFS module files not found - attempting DKMS rebuild"
    dkms autoinstall -k "$KERNEL_VERSION" || true
    depmod -a "$KERNEL_VERSION"
    
    # Check again after DKMS rebuild
    if find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f | grep -q .; then
        echo "✓ ZFS module files found after DKMS rebuild"
    else
        echo "✗ ZFS module files still not found - this may cause boot issues"
    fi
fi

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

function verify_initramfs {
    echo "======= Verifying initramfs contents =========="
    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail

echo "=== Checking initramfs for ZFS components ==="
for initrd in /boot/initrd.img-*; do
    if [ -f "$initrd" ]; then
        echo "Checking: $initrd"
        lsinitramfs "$initrd" | grep -E "(zfs|pool|dataset|spl)" | head -10 || echo "No ZFS components found (this might be normal for first check)"
        echo "---"
    fi
done

echo "=== Checking ZFS module files on disk ==="
KERNEL_VERSION=$(ls /lib/modules/ | head -n1)
find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f

echo "=== Testing ZFS commands ==="
which zpool && zpool --version || echo "zpool not found"
which zfs && zfs --version || echo "zfs not found"

echo "=== Checking DKMS status ==="
dkms status || echo "DKMS not available"

echo "=== Checking if ZFS tools are properly installed ==="
dpkg -l | grep -E "(zfs|spl)"

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
    dd bs=440 conv=notrunc count=1 if="/usr/lib/EXTLINUX/gptmbr.bin" of="$INSTALL_DISK"
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
    zfs set org.zfsbootmenu:commandline="ro quiet" "$ZFS_POOL/ROOT/debian"

    echo "Boot configuration:"
    zfs get org.zfsbootmenu:commandline "$ZFS_POOL/ROOT/debian"
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
systemctl enable systemd-networkd

systemctl enable zfs-import-cache
systemctl enable zfs-mount

systemctl enable ssh
systemctl enable apt-daily.timer

echo "Enabled services:"
systemctl list-unit-files | grep enabled
EOF
}

function configure_networking {
    echo "======= Configuring systemd-networkd for Hetzner Cloud =========="
    
    # Create systemd-networkd configuration for all ethernet interfaces
    mkdir -p "$TARGET/etc/systemd/network"
    
    cat > "$TARGET/etc/systemd/network/10-hetzner.network" <<'EOF'
[Match]
Name=ens* enp* eth*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes

[DHCP]
RouteMetric=100
UseDNS=yes
UseDomains=yes

[DHCPv4]
RouteMetric=100
UseDNS=yes
UseDomains=yes

[IPv6AcceptRA]
RouteMetric=100
EOF

    echo "systemd-networkd configuration:"
    cat "$TARGET/etc/systemd/network/10-hetzner.network"
    echo ""
}

# ---- Cleanup and Finalization Functions ----
function unmount_all_datasets_and_partitions {
    echo "======= Unmounting all datasets =========="
    
    # First, unmount virtual filesystems that might be using the datasets
    echo "Unmounting virtual filesystems..."
    for dir in dev/pts dev tmp run/lock run/shm run sys proc; do
        if mountpoint -q "$TARGET/$dir"; then
            echo "Unmounting $TARGET/$dir"
            umount "$TARGET/$dir" 2>/dev/null || true
        fi
    done
    
    # Give it a moment
    sleep 2
    
    # Try to unmount boot partition first
    if mountpoint -q "$MAIN_BOOT"; then
        echo "Unmounting boot partition from $MAIN_BOOT"
        umount "$MAIN_BOOT" 2>/dev/null || true
    fi
    
    # Unmount ZFS datasets
    echo "Unmounting ZFS datasets..."
    zfs umount -a 2>/dev/null || true
    
    # Wait for unmounts to complete
    sleep 2
    
    # If root dataset is still mounted, try lazy unmount
    if mountpoint -q "$TARGET"; then
        echo "Attempting lazy unmount of $TARGET"
        umount -l "$TARGET" 2>/dev/null || true
    fi
    
    # Force unmount any stubborn ZFS datasets
    if zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -q "yes"; then
        echo "Forcing unmount of remaining ZFS datasets..."
        zfs umount -a -f 2>/dev/null || true
    fi
    
    # Final verification and force unmount if still mounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted! Attempting final cleanup..."
        # Use fuser to find what's using the mount
        if command -v fuser &> /dev/null; then
            fuser -mv "$TARGET" 2>/dev/null || true
        fi
        # Force lazy unmount as last resort
        umount -l "$TARGET" 2>/dev/null || true
    fi
    
    # Final ZFS unmount check
    local mounted_count=0
    mounted_count=$(zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep -c "yes" || true)
    
    if [ "$mounted_count" -gt 0 ]; then
        echo "WARNING: $mounted_count dataset(s) still mounted:"
        zfs get mounted -r "$ZFS_POOL" 2>/dev/null | grep "yes" || true
    else
        echo "✓ All ZFS datasets successfully unmounted"
    fi
    
    # Verify $TARGET is unmounted
    if mountpoint -q "$TARGET"; then
        echo "WARNING: $TARGET is still mounted but continuing..."
    else
        echo "✓ $TARGET successfully unmounted"
    fi
    
    # Verify $MAIN_BOOT is unmounted
    if mountpoint -q "$MAIN_BOOT"; then
        echo "WARNING: $MAIN_BOOT is still mounted!"
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

function export_zfs_pool {
    echo "======= Exporting ZFS pool =========="
    # Export the pool to ensure clean state
    zpool export "$ZFS_POOL"
    echo "✓ ZFS pool '$ZFS_POOL' exported successfully"
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
    echo "  Debian Version: $DEBIAN_CODENAME"
    echo "  Networking: systemd-networkd + systemd-resolved"
    echo ""
    echo "=========================================="
    echo "Rebooting..."
}

# ---- Main Installation Flow ----
function main {
    echo "Starting ZFS Debian 13 installation on Hetzner..."
    
    # Get user input first
    get_user_input
    
    # System detection
    detect_efi
    find_install_disk
    
    # Show summary and get confirmation
    show_summary_and_confirm
    
    # Rescue system preparation
    remove_unused_kernels
    install_zfs_on_rescue_system
    
    # Disk partitioning
    partition_disk
    
    # ZFS setup
    create_zfs_pool
    
    # System installation
    bootstrap_debian_system
    setup_chroot_environment
    configure_basic_system
    install_system_packages
    
    verify_initramfs
    configure_ssh
    set_root_credentials
    
    # System configuration
    configure_system_services
    configure_networking
    
    # Bootloader configuration
    configure_bootloader
    
    # Finalization
    unmount_chroot_environment
   
    unmount_all_datasets_and_partitions
    set_final_mountpoints
    export_zfs_pool
    
    # Completion
    show_final_instructions
    
    reboot
}

# Run main function
main