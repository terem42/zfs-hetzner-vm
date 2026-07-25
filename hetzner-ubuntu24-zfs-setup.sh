#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Ubuntu 24.04 with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname, ZFS pool name, root password and ZFS ARC cache size
To cope with network failures its highly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-a then d
end_header_info

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- Configuration ----
# These will be set by user input
SYSTEM_HOSTNAME=""
ROOT_PASSWORD=""
ZFS_POOL=""
ZFS_ARC_MAX_MB=""
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

UBUNTU_KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"

# Global variables
INSTALL_DISK=""
EFI_MODE=false
BOOT_LABEL=""
BOOT_TYPE=""
BOOT_PART=""
ZFS_PART=""

function on_error {
    echo "" >&2
    echo "ERROR: installation failed at line $1 (exit code $2)." >&2
    echo "The system may be left in a partially installed state." >&2
    echo "Check mounts under $TARGET and $MAIN_BOOT and the state of pool '$ZFS_POOL' before re-running." >&2
}
trap 'on_error $LINENO $?' ERR

# ---- Preflight Checks ----
function check_prerequisites {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: this script must be run as root." >&2
        exit 1
    fi
    if [ ! -s /root/.ssh/authorized_keys ]; then
        echo "ERROR: /root/.ssh/authorized_keys is missing or empty." >&2
        echo "Add your SSH key in the Hetzner rescue console before booting rescue," >&2
        echo "otherwise you will be locked out of the installed system." >&2
        exit 1
    fi
}

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

function user_cancelled {
    echo "Installation cancelled by user."
    exit 1
}

function get_hostname {
    while true; do
        if ! SYSTEM_HOSTNAME=$(whiptail \
            --title " System Hostname " \
            --inputbox "\nEnter the hostname for the new system:" \
            10 60 "zfs-ubuntu" \
            3>&1 1>&2 2>&3); then
            user_cancelled
        fi

        # Validate hostname
        if [[ "$SYSTEM_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] && [[ ${#SYSTEM_HOSTNAME} -le 63 ]]; then
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
        if ! ZFS_POOL=$(whiptail \
            --title " ZFS Pool Name " \
            --inputbox "\nEnter the name for the ZFS pool:" \
            10 60 "rpool" \
            3>&1 1>&2 2>&3); then
            user_cancelled
        fi

        # Reject names reserved by ZFS
        case "$ZFS_POOL" in
            mirror*|raidz*|draid*|spare*|log)
                whiptail \
                    --title " Invalid Pool Name " \
                    --msgbox "Pool name must not begin with a ZFS reserved word (mirror, raidz, draid, spare, log)." \
                    10 60
                continue
                ;;
        esac

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
    local password1
    local password2
    while true; do
        if ! password1=$(whiptail \
            --title " Root Password " \
            --passwordbox "\nEnter root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3); then
            user_cancelled
        fi

        if ! password2=$(whiptail \
            --title " Confirm Root Password " \
            --passwordbox "\nConfirm root password (input hidden):" \
            10 60 \
            3>&1 1>&2 2>&3); then
            user_cancelled
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

function get_arc_size {
    local total_mb default_mb
    total_mb=$(free -m | awk '/^Mem:/ {print $2}')
    default_mb=$(( total_mb / 4 ))
    if (( default_mb < 64 )); then
        default_mb=64
    fi
    while true; do
        if ! ZFS_ARC_MAX_MB=$(whiptail \
            --title " ZFS ARC Cache Size " \
            --inputbox "\nEnter the maximum ZFS ARC cache size in MiB\n(system RAM: ${total_mb} MiB):" \
            11 60 "$default_mb" \
            3>&1 1>&2 2>&3); then
            user_cancelled
        fi

        if [[ "$ZFS_ARC_MAX_MB" =~ ^[0-9]+$ ]] && (( ZFS_ARC_MAX_MB >= 64 )) && (( ZFS_ARC_MAX_MB <= total_mb )); then
            break
        else
            whiptail \
                --title " Invalid ARC Size " \
                --msgbox "ARC size must be an integer between 64 and ${total_mb} (MiB)." \
                10 60
        fi
    done
}

function show_summary_and_confirm {
    local summary
    summary="Please review the installation settings:

Hostname: $SYSTEM_HOSTNAME
ZFS Pool: $ZFS_POOL
ZFS ARC max: $ZFS_ARC_MAX_MB MiB
Ubuntu Version: $UBUNTU_CODENAME (24.04)
Target: $TARGET
Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")
Install Disk: $INSTALL_DISK

*** WARNING: This will DESTROY ALL DATA on $INSTALL_DISK! ***

Do you want to continue with the installation?"

    if whiptail \
        --title " Installation Summary " \
        --yesno "$summary" \
        20 60; then
        echo "User confirmed installation. Starting now..."
    else
        user_cancelled
    fi
}

function get_user_input {
    echo "======= Gathering Installation Parameters =========="
    check_whiptail

    # Show welcome message
    if ! whiptail \
        --title " ZFS Ubuntu Installer " \
        --msgbox "Welcome to the ZFS Ubuntu Installer for Hetzner Cloud.\n\nThis script will install Ubuntu 24.04 with ZFS root on your server." \
        12 60; then
        user_cancelled
    fi

    # Get user inputs
    get_hostname
    get_zfs_pool_name
    get_root_password
    get_arc_size
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

    if [[ ${#candidate_disks[@]} -eq 1 ]]; then
        INSTALL_DISK="${candidate_disks[0]}"
        echo "Single candidate disk found: $INSTALL_DISK"
    else
        select_install_disk "${candidate_disks[@]}"
    fi

    echo "Using installation disk: $INSTALL_DISK"

    # Show all available disks for verification
    echo "All available disks:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,RO | grep -v loop
}

function select_install_disk {
    local disks=("$@")
    local menu_items=()
    local disk desc

    for disk in "${disks[@]}"; do
        # Describe each disk by size and model (model is empty on some virtio disks)
        desc=$(lsblk -dno SIZE,MODEL "$disk" 2>/dev/null | awk '{$1=$1; print}')
        menu_items+=("$disk" "${desc:-unknown}")
    done

    if ! INSTALL_DISK=$(whiptail \
        --title " Select Installation Disk " \
        --menu "\nMultiple candidate disks found. Select the disk to install to.\n\n*** ALL DATA on the chosen disk will be DESTROYED ***" \
        20 70 "${#disks[@]}" \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3); then
        user_cancelled
    fi
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

    # Enable backports of the rescue system's own release for a newer ZFS version
    local rescue_codename
    # shellcheck disable=SC1091
    rescue_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb ${MIRROR_SITE}/debian/packages ${rescue_codename}-backports main contrib" > /etc/apt/sources.list.d/backports.list
    apt update
    apt install -y -t "${rescue_codename}-backports" zfsutils-linux

    # The Hetzner rescue system ships static zfs/zpool binaries in /usr/local/sbin
    # that shadow the packaged ones; remove only those known copies
    rm -f /usr/local/sbin/zfs /usr/local/sbin/zpool
    hash -r
    export PATH=/usr/sbin:$PATH

    # The rescue kernel normally ships the ZFS module; build it via DKMS if missing
    if ! modprobe zfs; then
        echo "ZFS module not available in rescue kernel, building via DKMS..."
        apt install -y -t "${rescue_codename}-backports" "linux-headers-$(uname -r)" zfs-dkms
        modprobe zfs
    fi
}

# ---- Disk Partitioning Functions ----
function partition_disk {
    echo "======= Partitioning disk =========="
    sgdisk -Z "$INSTALL_DISK"

    # Boot partition (128 MiB is plenty for ZFSBootMenu), then ZFS on the rest
    sgdisk -n1:1M:+128M -t1:"$BOOT_TYPE" -c1:"$BOOT_LABEL" "$INSTALL_DISK"
    sgdisk -n2:0:0 -t2:bf00 -c2:"zfs" "$INSTALL_DISK"
    if [ "$EFI_MODE" != true ]; then
        # Legacy BIOS bootable attribute, scanned for by syslinux gptmbr.bin
        sgdisk -A 1:set:2 "$INSTALL_DISK"
    fi

    partprobe "$INSTALL_DISK" || true
    udevadm settle

    # Derive partition device names from the disk name; disks whose name ends in
    # a digit (nvme0n1, loop0) get a "p" separator before the partition number
    local part_prefix="$INSTALL_DISK"
    if [[ "$INSTALL_DISK" =~ [0-9]$ ]]; then
        part_prefix="${INSTALL_DISK}p"
    fi
    BOOT_PART="${part_prefix}1"
    ZFS_PART="${part_prefix}2"

    local part
    for part in "$BOOT_PART" "$ZFS_PART"; do
        if [ ! -b "$part" ]; then
            echo "ERROR: expected partition $part not found after partitioning" >&2
            exit 1
        fi
    done

    if [ "$EFI_MODE" = true ]; then
        # Format ESP as FAT32
        mkfs.fat -F 32 -n "$BOOT_LABEL" "$BOOT_PART"
    else
        mkfs.ext4 -F -L "$BOOT_LABEL" "$BOOT_PART"
    fi
}

# ---- ZFS Pool and Dataset Functions ----
function create_zfs_pool {
    echo "======= Creating ZFS pool =========="
    mkdir -p "$TARGET"

    # -R "$TARGET" (altroot) prefixes all mountpoints with $TARGET for the
    # lifetime of this import only, so datasets can be created with their final
    # mountpoints right away; altroot is never written to the pool
    zpool create -f -o ashift=12 \
    -o autotrim=on \
    -o cachefile="/etc/zfs/zpool.cache" \
    -R "$TARGET" \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O mountpoint=none \
    "$ZFS_POOL" "$ZFS_PART"

    zfs create -o mountpoint=none   "$ZFS_POOL/ROOT"
    zfs create -o mountpoint=legacy "$ZFS_POOL/ROOT/ubuntu"

    echo "======= Assigning $ZFS_POOL/ROOT/ubuntu dataset as bootable =========="
    zpool set bootfs="$ZFS_POOL/ROOT/ubuntu" "$ZFS_POOL"
}

function create_additional_zfs_datasets {
    echo "======= Creating additional ZFS datasets =========="
    # Mountpoints are final; while the pool is imported with altroot=$TARGET
    # they are automatically mounted under $TARGET

    # Ensure parent datasets are created first
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/ubuntu/var"
    zfs create -o mountpoint=none "$ZFS_POOL/ROOT/ubuntu/var/cache"

    zfs create -o com.sun:auto-snapshot=false -o devices=off -o mountpoint=/tmp "$ZFS_POOL/ROOT/ubuntu/tmp"
    zfs create -o com.sun:auto-snapshot=false -o devices=off -o mountpoint=/var/tmp "$ZFS_POOL/ROOT/ubuntu/var/tmp"
    zfs create -o atime=off -o mountpoint=/var/log "$ZFS_POOL/ROOT/ubuntu/var/log"
    zfs create -o com.sun:auto-snapshot=false -o atime=off -o mountpoint=/var/cache/apt "$ZFS_POOL/ROOT/ubuntu/var/cache/apt"

    # Create home dataset separately
    zfs create -o mountpoint=/home "$ZFS_POOL/home"

    # Mount any datasets not already auto-mounted
    zfs mount -a

    # Set permissions on the actual ZFS datasets
    echo "Setting permissions on ZFS datasets..."
    chmod 1777 "$TARGET/tmp" "$TARGET/var/tmp"
    echo "✓ Temp directory permissions set (1777)"

    echo ""
    echo "Detailed dataset listing:"
    zfs list -o name,mountpoint -r "$ZFS_POOL"
}

# ---- System Bootstrap Functions ----
function bootstrap_ubuntu_system {
    echo "======= Bootstrapping Ubuntu to temporary directory =========="

    # ubuntu-keyring is a regular Debian package, so it can be installed
    # (authenticated) straight from the rescue system's own repositories
    apt install -y mmdebstrap ubuntu-keyring

    if [ ! -f "$UBUNTU_KEYRING" ]; then
        echo "ERROR: $UBUNTU_KEYRING not found after installing ubuntu-keyring" >&2
        exit 1
    fi

    # NOTE: the rescue system runs from RAM, so the staging directory lives in
    # RAM too; the debootstrap variant of noble needs roughly 700 MB
    local TEMP_STAGE
    TEMP_STAGE=$(mktemp -d)
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

    mmdebstrap --variant=debootstrap \
      --keyring="$UBUNTU_KEYRING" \
      --include=systemd-resolved,locales,debconf-i18n,apt-utils,keyboard-configuration,console-setup,kbd,extlinux,initramfs-tools,zstd \
      "$UBUNTU_CODENAME" "$TEMP_STAGE" \
      "$MIRROR_MAIN" "$MIRROR_UPDATES" "$MIRROR_BACKPORTS" "$MIRROR_SECURITY"

    echo "======= Copying staged system to ZFS datasets =========="
    # Mount root dataset (legacy mountpoint, mounted manually)
    mount -t zfs "$ZFS_POOL/ROOT/ubuntu" "$TARGET"

    create_additional_zfs_datasets

    # Use rsync to copy the entire system (this will populate all datasets)
    echo "Copying staged system to ZFS datasets..."
    rsync -aAXH --numeric-ids "$TEMP_STAGE/" "$TARGET/"

    echo "Staged system copied successfully"
    echo "Source size: $(du -sh "$TEMP_STAGE")"
    echo "Target size: $(du -sh "$TARGET")"

    # Clean up temp directory
    cleanup_temp_stage
    trap - EXIT

    # systemd-resolved makes /etc/resolv.conf a symlink into /run, which is
    # dangling inside the chroot; use the rescue system's resolver during the
    # install (restored by restore_target_resolv_conf before reboot)
    rm -f "$TARGET/etc/resolv.conf"
    cp /etc/resolv.conf "$TARGET/etc/resolv.conf"
}

function configure_zfs_arc {
    echo "======= Configuring ZFS ARC cache size =========="
    mkdir -p "$TARGET/etc/modprobe.d"
    echo "options zfs zfs_arc_max=$(( ZFS_ARC_MAX_MB * 1024 * 1024 ))" > "$TARGET/etc/modprobe.d/zfs.conf"
    cat "$TARGET/etc/modprobe.d/zfs.conf"
}

function setup_chroot_environment {
    echo "======= Mounting virtual filesystems for chroot =========="
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sysfs "$TARGET/sys"
    mount -t tmpfs tmpfs "$TARGET/run"
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

# Configure keyboard for German and Russian with Ctrl+Shift toggle
cat > /etc/default/keyboard <<'KEYBOARD'
# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="de,ru"
XKBVARIANT=","
XKBOPTIONS="grp:ctrl_shift_toggle"

BACKSPACE="guess"
KEYBOARD

# Compile the console keyboard configuration without touching the
# (nonexistent) console of the chroot
setupcon --save-only || true

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

# Generate a stable hostid; zfs-initramfs embeds /etc/hostid in the initramfs
# so the pool import at boot uses a consistent identity
zgenhostid -f
echo "hostid: $(hostid)"

# Get the actual kernel version installed in the chroot
KERNEL_VERSION=$(ls /lib/modules/ | head -n1)
echo "Detected kernel version: $KERNEL_VERSION"

# Verify ZFS module is available in the chroot filesystem
echo "=== Verifying ZFS module in chroot ==="
if find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f | grep -q .; then
    echo "✓ ZFS module files found in /lib/modules/$KERNEL_VERSION/"
else
    echo "✗ ZFS module files not found - attempting DKMS rebuild"
    dkms autoinstall -k "$KERNEL_VERSION" || true
    depmod -a "$KERNEL_VERSION"

    # Check again after DKMS rebuild
    if find "/lib/modules/$KERNEL_VERSION" -name "*zfs*" -type f | grep -q .; then
        echo "✓ ZFS module files found after DKMS rebuild"
    else
        echo "✗ ZFS module files still not found - aborting, system would be unbootable" >&2
        exit 1
    fi
fi

# Ensure ZFS module is included in initramfs
grep -qxF "zfs" /etc/initramfs-tools/modules || echo "zfs" >> /etc/initramfs-tools/modules

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
    chmod 700 "$TARGET/root/.ssh"
    chmod 600 "$TARGET/root/.ssh/authorized_keys"
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' "$TARGET/etc/ssh/sshd_config"
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' "$TARGET/etc/ssh/sshd_config"

    chroot "$TARGET" /bin/bash <<'EOF'
set -euo pipefail
rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server -f noninteractive
EOF
}

function set_root_credentials {
    echo "======= Setting root password =========="
    printf 'root:%s\n' "$ROOT_PASSWORD" | chroot "$TARGET" chpasswd

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
    curl -fSL --retry 3 --retry-delay 5 "$ZBM_EFI_URL" -o "$MAIN_BOOT/EFI/Boot/bootx64.efi"

    # Reference the ESP in fstab (not auto-mounted; mount manually to update ZBM)
    mkdir -p "$TARGET/boot/efi"
    echo "PARTLABEL=${BOOT_LABEL} /boot/efi vfat noauto,umask=0077 0 0" >> "$TARGET/etc/fstab"
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
    local TEMP_ZBM
    TEMP_ZBM=$(mktemp -d)
    echo "Downloading ZFSBootMenu for BIOS from: $ZBM_BIOS_URL"
    curl -fSL --retry 3 --retry-delay 5 "$ZBM_BIOS_URL" -o "$TEMP_ZBM/zbm.tar.gz"
    tar -xz -C "$TEMP_ZBM" -f "$TEMP_ZBM/zbm.tar.gz" --strip-components=1

    # Copy ZFSBootMenu to boot partition
    mkdir -p "$MAIN_BOOT/zfsbootmenu"
    cp "$TEMP_ZBM"/vmlinuz* "$MAIN_BOOT/zfsbootmenu/"
    cp "$TEMP_ZBM"/initramfs* "$MAIN_BOOT/zfsbootmenu/"

    # Clean up
    rm -rf "$TEMP_ZBM"

    echo "ZFSBootMenu files copied to boot partition:"
    ls -la "$MAIN_BOOT/zfsbootmenu/"

    # Install GPT-aware MBR boot code; it chain-loads the partition carrying the
    # legacy BIOS bootable attribute set by sgdisk in partition_disk.
    # Prefer the rescue system's copy, fall back to the one staged in the target.
    local gptmbr=""
    local candidate
    for candidate in /usr/lib/EXTLINUX/gptmbr.bin "$TARGET/usr/lib/EXTLINUX/gptmbr.bin"; do
        if [ -f "$candidate" ]; then
            gptmbr="$candidate"
            break
        fi
    done
    if [ -z "$gptmbr" ]; then
        echo "ERROR: gptmbr.bin not found in rescue system or target" >&2
        exit 1
    fi
    dd bs=440 conv=notrunc count=1 if="$gptmbr" of="$INSTALL_DISK"

    # Reference the boot partition in fstab (not auto-mounted; mount manually to update ZBM)
    mkdir -p "$TARGET/boot/syslinux"
    echo "LABEL=${BOOT_LABEL} /boot/syslinux ext4 noauto,defaults 0 2" >> "$TARGET/etc/fstab"

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
# netplan renders to systemd-networkd, which must be enabled explicitly
systemctl enable systemd-networkd

systemctl enable zfs-import-cache
systemctl enable zfs-mount

systemctl enable ssh
systemctl enable apt-daily.timer

echo "Enabled services:"
systemctl list-unit-files | grep enabled || true
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
function restore_target_resolv_conf {
    echo "======= Restoring systemd-resolved resolv.conf symlink =========="
    rm -f "$TARGET/etc/resolv.conf"
    ln -s ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"
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

function unmount_all_datasets_and_partitions {
    echo "======= Unmounting all datasets =========="

    # First, unmount any virtual filesystems still using the datasets
    echo "Unmounting virtual filesystems..."
    for dir in dev/pts dev tmp run sys proc; do
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

    # The root dataset has a legacy mountpoint, so unmount it explicitly
    if mountpoint -q "$TARGET"; then
        umount "$TARGET" 2>/dev/null || {
            echo "Attempting lazy unmount of $TARGET"
            umount -l "$TARGET" 2>/dev/null || true
        }
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

function export_zfs_pool {
    echo "======= Exporting ZFS pool =========="
    # Export the pool to ensure clean state
    if ! zpool export "$ZFS_POOL"; then
        echo "Plain export failed, retrying with force..."
        sleep 2
        zpool export -f "$ZFS_POOL"
    fi
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
    echo "  ZFS ARC max: $ZFS_ARC_MAX_MB MiB"
    echo "  Boot Mode: $([ "$EFI_MODE" = true ] && echo "EFI" || echo "BIOS")"
    echo "  Ubuntu Version: $UBUNTU_CODENAME"
    echo "  Networking: netplan (systemd-networkd) + systemd-resolved"
    echo ""
    echo "=========================================="
    echo "Rebooting..."
}

# ---- Main Execution Function ----
function main {
    echo "Starting ZFS Ubuntu installation on Hetzner Cloud..."

    check_prerequisites

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
    configure_zfs_arc
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
    restore_target_resolv_conf
    unmount_chroot_environment
    unmount_all_datasets_and_partitions
    export_zfs_pool

    show_final_instructions

    reboot
}

# Execute main function
main "$@"
