#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic script to install Ubuntu 20 LTS with ZFS root on Hetzner VPS
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, set it OS to linux64, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname and ZFS ARC cache size
To cope with network failures its higly recommended to run the script inside screen console
screen -dmS zfs
screen -r zfs
To detach from screen console, hit Ctrl-d then a
end_header_info

set -o errexit
set -o pipefail
set -o nounset

export TMPDIR=/tmp

# Variables
v_bpool_name=
v_bpool_tweaks=
v_rpool_name=
v_rpool_tweaks=
declare -a v_selected_disks
v_swap_size=                 # integer
v_free_tail_space=           # integer
v_hostname=
v_kernel_variant=
v_zfs_arc_max_mb=
v_root_password=
v_encrypt_rpool=             # 0=false, 1=true
v_passphrase=
v_zfs_experimental=
v_suitable_disks=()

# Constants
c_deb_packages_repo=http://mirror.hetzner.de/ubuntu/packages
c_deb_security_repo=http://mirror.hetzner.de/ubuntu/security

c_default_zfs_arc_max_mb=250
c_default_bpool_tweaks="-o ashift=12 -O compression=lz4"
c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=zstd-9 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_default_hostname=terem
c_zfs_mount_dir=/mnt
c_log_dir=$(dirname "$(mktemp)")/zfs-hetzner-vm
c_install_log=$c_log_dir/install.log
c_lsb_release_log=$c_log_dir/lsb_release.log
c_disks_log=$c_log_dir/disks.log

function activate_debug {
  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}

# shellcheck disable=SC2120
function print_step_info_header {
  echo -n "
###############################################################################
# ${FUNCNAME[1]}"

  if [[ "${1:-}" != "" ]]; then
    echo -n " $1" 
  fi

  echo "
###############################################################################
"
}

function print_variables {
  for variable_name in "$@"; do
    declare -n variable_reference="$variable_name"

    echo -n "$variable_name:"

    case "$(declare -p "$variable_name")" in
    "declare -a"* )
      for entry in "${variable_reference[@]}"; do
        echo -n " \"$entry\""
      done
      ;;
    "declare -A"* )
      for key in "${!variable_reference[@]}"; do
        echo -n " $key=\"${variable_reference[$key]}\""
      done
      ;;
    * )
      echo -n " $variable_reference"
      ;;
    esac

    echo
  done

  echo
}

function display_intro_banner {
  # shellcheck disable=SC2119
  print_step_info_header

  local dialog_message='Hello!
This script will prepare the ZFS pools, then install and configure minimal Ubuntu 20 LTS with ZFS root on Hetzner hosting VPS instance
The script with minimal changes may be used on any other hosting provider  supporting KVM virtualization and offering Debian-based rescue system.
In order to stop the procedure, hit Esc twice during dialogs (excluding yes/no ones), or Ctrl+C while any operation is running.
'
  dialog --msgbox "$dialog_message" 30 100
}

function store_os_distro_information {
  # shellcheck disable=SC2119
  print_step_info_header

  lsb_release --all > "$c_lsb_release_log"
}

function check_prerequisites {
  # shellcheck disable=SC2119
  print_step_info_header
  if [[ $(id -u) -ne 0 ]]; then
    echo 'This script must be run with administrative privileges!'
    exit 1
  fi
  if [[ ! -r /root/.ssh/authorized_keys ]]; then
    echo "SSH pubkey file is absent, please add it to the rescue system setting, then reboot into rescue system and run the script"
    exit 1
  fi
  if ! dpkg-query --showformat="\${Status}" -W dialog 2> /dev/null | grep -q "install ok installed"; then
    apt install --yes dialog
  fi
}


function find_suitable_disks {
  # shellcheck disable=SC2119
  print_step_info_header

  udevadm trigger

  # shellcheck disable=SC2012
  ls -l /dev/disk/by-id | tail -n +2 | perl -lane 'print "@F[8..10]"' > "$c_disks_log"

  local candidate_disk_ids
  local mounted_devices

  candidate_disk_ids=$(find /dev/disk/by-id -regextype awk -regex '.+/(ata|nvme|scsi)-.+' -not -regex '.+-part[0-9]+$' | sort)
  mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"

  while read -r disk_id || [[ -n "$disk_id" ]]; do
    local device_info

    device_info="$(udevadm info --query=property "$(readlink -f "$disk_id")")"
    block_device_basename="$(basename "$(readlink -f "$disk_id")")"

    if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then
      if ! grep -q "^$block_device_basename\$" <<< "$mounted_devices"; then
        v_suitable_disks+=("$disk_id")
      fi
    fi

    cat >> "$c_disks_log" << LOG

## DEVICE: $disk_id ################################

$(udevadm info --query=property "$(readlink -f "$disk_id")")

LOG

  done < <(echo -n "$candidate_disk_ids")

  if [[ ${#v_suitable_disks[@]} -eq 0 ]]; then
    local dialog_message='No suitable disks have been found!

If you think this is a bug, please open an issue on https://github.com/terem42/zfs-hetzner-vm/issues, and attach the file `'"$c_disks_log"'`.
'
    dialog --msgbox "$dialog_message" 30 100

    exit 1
  fi

  print_variables v_suitable_disks
}

function select_disks {
  # shellcheck disable=SC2119
  print_step_info_header

  while true; do
    local menu_entries_option=()

    if [[ ${#v_suitable_disks[@]} -eq 1 ]]; then
      local disk_selection_status=ON
    else
      local disk_selection_status=OFF
    fi

    for disk_id in "${v_suitable_disks[@]}"; do
      menu_entries_option+=("$disk_id" "($block_device_basename)" "$disk_selection_status")
    done

    local dialog_message="Select the ZFS devices (multiple selections will be in mirror).

Devices with mounted partitions, cdroms, and removable devices are not displayed!
"
    mapfile -t v_selected_disks < <(dialog --separate-output --checklist "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)

    if [[ ${#v_selected_disks[@]} -gt 0 ]]; then
      break
    fi
  done

  print_variables v_selected_disks
}

function ask_swap_size {
  # shellcheck disable=SC2119
  print_step_info_header

  local swap_size_invalid_message=

  while [[ ! $v_swap_size =~ ^[0-9]+$ ]]; do
    v_swap_size=$(dialog --inputbox "${swap_size_invalid_message}Enter the swap size in GiB (0 for no swap):" 30 100 2 3>&1 1>&2 2>&3)

    swap_size_invalid_message="Invalid swap size! "
  done

  print_variables v_swap_size
}

function ask_free_tail_space {
  # shellcheck disable=SC2119
  print_step_info_header

  local tail_space_invalid_message=

  while [[ ! $v_free_tail_space =~ ^[0-9]+$ ]]; do
    v_free_tail_space=$(dialog --inputbox "${tail_space_invalid_message}Enter the space to leave at the end of each disk (0 for none):" 30 100 0 3>&1 1>&2 2>&3)

    tail_space_invalid_message="Invalid size! "
  done

  print_variables v_free_tail_space
}

function ask_zfs_arc_max_size {
  # shellcheck disable=SC2119
  print_step_info_header

  local zfs_arc_max_invalid_message=

  while [[ ! $v_zfs_arc_max_mb =~ ^[0-9]+$ ]]; do
    v_zfs_arc_max_mb=$(dialog --inputbox "${zfs_arc_max_invalid_message}Enter ZFS ARC cache max size in Mb (minimum 64Mb, enter 0 for ZFS default value, the default will take up to 50% of memory):" 30 100 "$c_default_zfs_arc_max_mb" 3>&1 1>&2 2>&3)

    zfs_arc_max_invalid_message="Invalid size! "
  done

  print_variables v_zfs_arc_max_mb
}


function ask_pool_names {
  # shellcheck disable=SC2119
  print_step_info_header

  local bpool_name_invalid_message=

  while [[ ! $v_bpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
    v_bpool_name=$(dialog --inputbox "${bpool_name_invalid_message}Insert the name for the boot pool" 30 100 bpool 3>&1 1>&2 2>&3)

    bpool_name_invalid_message="Invalid pool name! "
  done
  local rpool_name_invalid_message=

  while [[ ! $v_rpool_name =~ ^[a-z][a-zA-Z_:.-]+$ ]]; do
    v_rpool_name=$(dialog --inputbox "${rpool_name_invalid_message}Insert the name for the root pool" 30 100 rpool 3>&1 1>&2 2>&3)

    rpool_name_invalid_message="Invalid pool name! "
  done

  print_variables v_bpool_name v_rpool_name
}

function ask_pool_tweaks {
  # shellcheck disable=SC2119
  print_step_info_header

  v_bpool_tweaks=$(dialog --inputbox "Insert the tweaks for the boot pool" 30 100 -- "$c_default_bpool_tweaks" 3>&1 1>&2 2>&3)
  v_rpool_tweaks=$(dialog --inputbox "Insert the tweaks for the root pool" 30 100 -- "$c_default_rpool_tweaks" 3>&1 1>&2 2>&3)

  print_variables v_bpool_tweaks v_rpool_tweaks
}


function ask_root_password {
  # shellcheck disable=SC2119
  print_step_info_header

  set +x
  local password_invalid_message=
  local password_repeat=-

  while [[ "$v_root_password" != "$password_repeat" || "$v_root_password" == "" ]]; do
    v_root_password=$(dialog --passwordbox "${password_invalid_message}Please enter the root account password (can't be empty):" 30 100 3>&1 1>&2 2>&3)
    password_repeat=$(dialog --passwordbox "Please repeat the password:" 30 100 3>&1 1>&2 2>&3)

    password_invalid_message="Passphrase empty, or not matching! "
  done
  set -x
}

function ask_encryption {
  print_step_info_header

  if dialog --defaultno --yesno 'Do you want to encrypt the root pool?' 30 100; then
    v_encrypt_rpool=1
  fi
  set +x
  if [[ $v_encrypt_rpool == "1" ]]; then
    local passphrase_invalid_message=
    local passphrase_repeat=-
    while [[ "$v_passphrase" != "$passphrase_repeat" || ${#v_passphrase} -lt 8 ]]; do
      v_passphrase=$(dialog --passwordbox "${passphrase_invalid_message}Please enter the passphrase for the root pool (8 chars min.):" 30 100 3>&1 1>&2 2>&3)
      passphrase_repeat=$(dialog --passwordbox "Please repeat the passphrase:" 30 100 3>&1 1>&2 2>&3)

      passphrase_invalid_message="Passphrase too short, or not matching! "
    done
  fi
  set -x
}

function ask_zfs_experimental {
  print_step_info_header

  if dialog --defaultno --yesno 'Do you want to use experimental zfs module build?' 30 100; then
    v_zfs_experimental=1
  fi
}

function ask_hostname {
  # shellcheck disable=SC2119
  print_step_info_header

  local hostname_invalid_message=

  while [[ ! $v_hostname =~ ^[a-z][a-zA-Z0-9_:.-]+$ ]]; do
    v_hostname=$(dialog --inputbox "${hostname_invalid_message}Set the host name" 30 100 "$c_default_hostname" 3>&1 1>&2 2>&3)

    hostname_invalid_message="Invalid host name! "
  done

  print_variables v_hostname
}

function determine_kernel_variant {
  if dmidecode | grep -q vServer; then
    v_kernel_variant="-virtual"
  else
    v_kernel_variant="-generic"
  fi
}

function chroot_execute {
  chroot $c_zfs_mount_dir bash -c "$1"
}

function unmount_and_export_fs {
  # shellcheck disable=SC2119
  print_step_info_header

  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
    fi
  done

  SECONDS=0
  zpools_exported=99
  echo "===========exporting zfs pools============="
  set +e
  while (( zpools_exported == 99 )) && (( SECONDS++ <= 60 )); do
    
    if zpool export -a 2> /dev/null; then
      zpools_exported=1
      echo "all zfs pools were succesfully exported"
      break;
    else
      sleep 1
     fi
  done
  set -e
  if (( zpools_exported != 1 )); then
    echo "failed to export zfs pools"
    exit 1
  fi
}

#################### MAIN ################################
export LC_ALL=en_US.UTF-8
export NCURSES_NO_UTF8_ACS=1

check_prerequisites

display_intro_banner

activate_debug

find_suitable_disks

select_disks

ask_swap_size

ask_free_tail_space

ask_pool_names

ask_pool_tweaks

ask_encryption

ask_zfs_arc_max_size

ask_zfs_experimental

ask_root_password

ask_hostname

determine_kernel_variant

clear

echo "===========remove unused kernels in rescue system========="
for kver in $(find /lib/modules/* -maxdepth 0 -type d | grep -v "$(uname -r)" | cut -s -d "/" -f 4); do
  apt purge --yes "linux-headers-$kver"
  apt purge --yes "linux-image-$kver"
done

echo "======= installing zfs on rescue system =========="
  echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections  
#  echo "y" | zfs
# linux-headers-generic linux-image-generic
  apt install --yes software-properties-common dpkg-dev dkms
  rm -f "$(which zfs)"
  rm -f "$(which zpool)"
  echo -e "deb http://deb.debian.org/debian/ testing main contrib non-free\ndeb http://deb.debian.org/debian/ testing main contrib non-free\n" >/etc/apt/sources.list.d/bookworm-testing.list
  echo -e "Package: src:zfs-linux\nPin: release n=testing\nPin-Priority: 990\n" > /etc/apt/preferences.d/90_zfs
  apt update  
  apt install -t testing --yes zfs-dkms zfsutils-linux
  rm /etc/apt/sources.list.d/bookworm-testing.list
  rm /etc/apt/preferences.d/90_zfs
  apt update
  export PATH=$PATH:/usr/sbin
  zfs --version

echo "======= partitioning the disk =========="

  if [[ $v_free_tail_space -eq 0 ]]; then
    tail_space_parameter=0
  else
    tail_space_parameter="-${v_free_tail_space}G"
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    wipefs --all --force "$selected_disk"
    sgdisk -a1 -n1:24K:+1000K            -t1:EF02 "$selected_disk"
    sgdisk -n2:0:+2G                   -t2:BF01 "$selected_disk" # Boot pool
    sgdisk -n3:0:"$tail_space_parameter" -t3:BF01 "$selected_disk" # Root pool
  done

  udevadm settle

echo "======= create zfs pools and datasets =========="

  encryption_options=()
  rpool_disks_partitions=()
  bpool_disks_partitions=()

  if [[ $v_encrypt_rpool == "1" ]]; then
    encryption_options=(-O "encryption=aes-256-gcm" -O "keylocation=prompt" -O "keyformat=passphrase")
  fi

  for selected_disk in "${v_selected_disks[@]}"; do
    rpool_disks_partitions+=("${selected_disk}-part3")
    bpool_disks_partitions+=("${selected_disk}-part2")
  done

  if [[ ${#v_selected_disks[@]} -gt 1 ]]; then
    pools_mirror_option=mirror
  else
    pools_mirror_option=
  fi

# shellcheck disable=SC2086
zpool create \
  $v_bpool_tweaks -O canmount=off -O devices=off \
  -o cachefile=/etc/zpool.cache \
  -O mountpoint=/boot -R $c_zfs_mount_dir -f \
  $v_bpool_name $pools_mirror_option "${bpool_disks_partitions[@]}"

# shellcheck disable=SC2086
echo -n "$v_passphrase" | zpool create \
  $v_rpool_tweaks \
  -o cachefile=/etc/zpool.cache \
  "${encryption_options[@]}" \
  -O mountpoint=/ -R $c_zfs_mount_dir -f \
  $v_rpool_name $pools_mirror_option "${rpool_disks_partitions[@]}"

zfs create -o canmount=off -o mountpoint=none "$v_rpool_name/ROOT"
zfs create -o canmount=off -o mountpoint=none "$v_bpool_name/BOOT"

zfs create -o canmount=noauto -o mountpoint=/ "$v_rpool_name/ROOT/ubuntu"
zfs mount "$v_rpool_name/ROOT/ubuntu"

zfs create -o canmount=noauto -o mountpoint=/boot "$v_bpool_name/BOOT/ubuntu"
zfs mount "$v_bpool_name/BOOT/ubuntu"

zfs create                                 "$v_rpool_name/home"
#zfs create -o mountpoint=/root             "$v_rpool_name/home/root"
zfs create -o canmount=off                 "$v_rpool_name/var"
zfs create                                 "$v_rpool_name/var/log"
zfs create                                 "$v_rpool_name/var/spool"

zfs create -o com.sun:auto-snapshot=false  "$v_rpool_name/var/cache"
zfs create -o com.sun:auto-snapshot=false  "$v_rpool_name/var/tmp"
chmod 1777 "$c_zfs_mount_dir/var/tmp"

zfs create                                 "$v_rpool_name/srv"

zfs create -o canmount=off                 "$v_rpool_name/usr"
zfs create                                 "$v_rpool_name/usr/local"

zfs create                                 "$v_rpool_name/var/mail"

zfs create -o com.sun:auto-snapshot=false -o canmount=on -o mountpoint=/tmp "$v_rpool_name/tmp"
chmod 1777 "$c_zfs_mount_dir/tmp"

if [[ $v_swap_size -gt 0 ]]; then
  zfs create \
    -V "${v_swap_size}G" -b "$(getconf PAGESIZE)" \
    -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false \
    "$v_rpool_name/swap"

  udevadm settle

  mkswap -f "/dev/zvol/$v_rpool_name/swap"
fi

echo "======= setting up initial system packages =========="
debootstrap --arch=amd64 jammy "$c_zfs_mount_dir" "$c_deb_packages_repo"

zfs set devices=off "$v_rpool_name"

echo "======= setting up the network =========="

echo "$v_hostname" > $c_zfs_mount_dir/etc/hostname

cat > "$c_zfs_mount_dir/etc/hosts" <<CONF
127.0.1.1 ${v_hostname}
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
CONF

ip6addr_prefix=$(ip -6 a s | grep -E "inet6.+global" | sed -nE 's/.+inet6\s(([0-9a-z]{1,4}:){4,4}).+/\1/p' | head -n 1)

cat <<CONF > /mnt/etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
DHCP=ipv4
Address=${ip6addr_prefix}:1/64
Gateway=fe80::1
CONF

chroot_execute "systemctl enable systemd-networkd.service"
chroot_execute "systemctl enable systemd-resolved.service"


mkdir -p "$c_zfs_mount_dir/etc/cloud/cloud.cfg.d/"
cat > "$c_zfs_mount_dir/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" <<CONF
network:
  config: disabled
CONF

rm -rf $c_zfs_mount_dir/etc/network/interfaces.d/50-cloud-init.cfg

echo "======= preparing the jail for chroot =========="
for virtual_fs_dir in proc sys dev; do
  mount --rbind "/$virtual_fs_dir" "$c_zfs_mount_dir/$virtual_fs_dir"
done

echo "======= setting apt repos =========="
cat > "$c_zfs_mount_dir/etc/apt/sources.list" <<CONF
deb [arch=i386,amd64] $c_deb_packages_repo jammy main restricted
deb [arch=i386,amd64] $c_deb_packages_repo jammy-updates main restricted
deb [arch=i386,amd64] $c_deb_packages_repo jammy-backports main restricted
deb [arch=i386,amd64] $c_deb_packages_repo jammy universe
deb [arch=i386,amd64] $c_deb_security_repo jammy-security main restricted
CONF

chroot_execute "apt update"

echo "======= setting locale, console and language =========="
chroot_execute "apt --yes --fix-broken install"
chroot_execute "apt install --yes -qq locales debconf-i18n apt-utils keyboard-configuration console-setup"
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# de_AT.UTF-8/de_AT.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# de_DE.UTF-8/de_DE.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"

chroot_execute 'cat <<CONF | debconf-set-selections
locales locales/default_environment_locale      select  en_US.UTF-8
keyboard-configuration  keyboard-configuration/store_defaults_in_debconf_db     boolean true
keyboard-configuration  keyboard-configuration/variant  select  German
keyboard-configuration  keyboard-configuration/unsupported_layout       boolean true
keyboard-configuration  keyboard-configuration/modelcode        string  pc105
keyboard-configuration  keyboard-configuration/unsupported_config_layout        boolean true
keyboard-configuration  keyboard-configuration/layout   select  German
keyboard-configuration  keyboard-configuration/layoutcode       string  de
keyboard-configuration  keyboard-configuration/optionscode      string
keyboard-configuration  keyboard-configuration/toggle   select  No toggling
keyboard-configuration  keyboard-configuration/xkb-keymap       select  de
keyboard-configuration  keyboard-configuration/switch   select  No temporary switch
keyboard-configuration  keyboard-configuration/unsupported_config_options       boolean true
keyboard-configuration  keyboard-configuration/ctrl_alt_bksp    boolean false
keyboard-configuration  keyboard-configuration/variantcode      string
keyboard-configuration  keyboard-configuration/model    select  Generic 105-key PC (intl.)
keyboard-configuration  keyboard-configuration/altgr    select  The default for the keyboard layout
keyboard-configuration  keyboard-configuration/compose  select  No compose key
keyboard-configuration  keyboard-configuration/unsupported_options      boolean true
console-setup   console-setup/fontsize-fb47     select  8x16
console-setup   console-setup/store_defaults_in_debconf_db      boolean true
console-setup   console-setup/codeset47 select  # Latin1 and Latin5 - western Europe and Turkic languages
console-setup   console-setup/fontface47        select  Fixed
console-setup   console-setup/fontsize  string  8x16
console-setup   console-setup/charmap47 select  UTF-8
console-setup   console-setup/fontsize-text47   select  8x16
console-setup   console-setup/codesetcode       string  Lat15
tzdata tzdata/Areas select Europe
tzdata tzdata/Zones/Europe select Vienna
grub-pc grub-pc/install_devices_empty   boolean true
CONF'

chroot_execute "dpkg-reconfigure locales -f noninteractive"
echo -e "LC_ALL=en_US.UTF-8\nLANG=en_US.UTF-8\n" >> "$c_zfs_mount_dir/etc/environment"
chroot_execute "dpkg-reconfigure keyboard-configuration -f noninteractive"
chroot_execute "dpkg-reconfigure console-setup -f noninteractive"
chroot_execute "setupcon"

chroot_execute "rm -f /etc/localtime /etc/timezone"
chroot_execute "dpkg-reconfigure tzdata -f noninteractive "

echo "======= installing latest kernel============="
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes linux-headers${v_kernel_variant} linux-image${v_kernel_variant}"
if [[ $v_kernel_variant == "-virtual" ]]; then
  # linux-image-extra is only available for virtual hosts
  chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes linux-image-extra-virtual"
fi


echo "======= installing aux packages =========="
chroot_execute "apt install --yes man-db wget curl software-properties-common nano htop gnupg"
chroot_execute "systemctl disable thermald"

echo "======= installing zfs packages =========="
chroot_execute 'echo "zfs-dkms zfs-dkms/note-incompatible-licenses note true" | debconf-set-selections'

if [[ $v_zfs_experimental == "1" ]]; then
  chroot_execute "wget -O - https://terem42.github.io/zfs-debian/apt_pub.gpg | apt-key add -"
  chroot_execute "add-apt-repository 'deb https://terem42.github.io/zfs-debian/public zfs-debian-experimental main'"
  chroot_execute "apt update"
  chroot_execute "apt install -t zfs-debian-experimental --yes zfs-initramfs zfs-dkms zfsutils-linux"
else
  chroot_execute "add-apt-repository --yes ppa:jonathonf/zfs"
  chroot_execute "apt install --yes zfs-initramfs zfs-dkms zfsutils-linux"
fi
chroot_execute 'cat << DKMS > /etc/dkms/zfs.conf
# override for /usr/src/zfs-*/dkms.conf:
# always rebuild initrd when zfs module has been changed
# (either by a ZFS update or a new kernel version)
REMAKE_INITRD="yes"
DKMS'

echo "======= installing OpenSSH and network tooling =========="
chroot_execute "apt install --yes openssh-server net-tools"

echo "======= setup OpenSSH  =========="
mkdir -p "$c_zfs_mount_dir/root/.ssh/"
cp /root/.ssh/authorized_keys "$c_zfs_mount_dir/root/.ssh/authorized_keys"
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' "$c_zfs_mount_dir/etc/ssh/sshd_config"
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/g' "$c_zfs_mount_dir/etc/ssh/sshd_config"
chroot_execute "rm /etc/ssh/ssh_host_*"
chroot_execute "dpkg-reconfigure openssh-server -f noninteractive"

echo "======= set root password =========="
chroot_execute "echo root:$(printf "%q" "$v_root_password") | chpasswd"

echo "======= setting up zfs cache =========="
cp /etc/zpool.cache /mnt/etc/zfs/zpool.cache

echo "========setting up zfs module parameters========"
chroot_execute "echo options zfs zfs_arc_max=$((v_zfs_arc_max_mb * 1024 * 1024)) >> /etc/modprobe.d/zfs.conf"

echo "======= setting up grub =========="
chroot_execute "echo 'grub-pc grub-pc/install_devices_empty   boolean true' | debconf-set-selections"
chroot_execute "DEBIAN_FRONTEND=noninteractive apt install --yes grub-pc"
chroot_execute "grub-install ${v_selected_disks[0]}"

chroot_execute "sed -i 's/#GRUB_TERMINAL=console/GRUB_TERMINAL=console/g' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"net.ifnames=0\"|' /etc/default/grub"
chroot_execute "sed -i 's|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"root=ZFS=$v_rpool_name/ROOT/ubuntu\"|g' /etc/default/grub"

chroot_execute "sed -i 's/quiet//g' /etc/default/grub"
chroot_execute "sed -i 's/splash//g' /etc/default/grub"
chroot_execute "echo 'GRUB_DISABLE_OS_PROBER=true'   >> /etc/default/grub"

for ((i = 1; i < ${#v_selected_disks[@]}; i++)); do
  dd if="${v_selected_disks[0]}-part1" of="${v_selected_disks[i]}-part1"
done

if [[ $v_encrypt_rpool == "1" ]]; then
  echo "=========set up dropbear=============="
  chroot_execute "apt install --yes dropbear-initramfs"
  
  mkdir -p "$c_zfs_mount_dir/etc/dropbear/initramfs"
  cp /root/.ssh/authorized_keys "$c_zfs_mount_dir/etc/dropbear/initramfs/authorized_keys"

  cp "$c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key" "$c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key_temp"
  chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_rsa_key_temp"
  chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key_temp /etc/dropbear/initramfs/dropbear_rsa_host_key"
  rm -rf "$c_zfs_mount_dir/etc/ssh/ssh_host_rsa_key_temp"

  cp "$c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key" "$c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key_temp"
  chroot_execute "ssh-keygen -p -i -m pem -N '' -f /etc/ssh/ssh_host_ecdsa_key_temp"
  chroot_execute "/usr/lib/dropbear/dropbearconvert openssh dropbear /etc/ssh/ssh_host_ecdsa_key_temp /etc/dropbear/initramfs/dropbear_ecdsa_host_key"
  chroot_execute "rm -rf /etc/ssh/ssh_host_ecdsa_key_temp"
  rm -rf "$c_zfs_mount_dir/etc/ssh/ssh_host_ecdsa_key_temp"

  rm -rf "$c_zfs_mount_dir/etc/dropbear/initramfs/dropbear_dss_host_key"
fi

echo "============setup root prompt============"
cat > "$c_zfs_mount_dir/root/.bashrc" <<CONF
export PS1='\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]'
umask 022
export LS_OPTIONS='--color=auto -h'
eval "\$(dircolors)"
CONF

echo "========running packages upgrade==========="
chroot_execute "apt upgrade --yes"
chroot_execute "apt purge cryptsetup* --yes"

echo "===========add static route to initramfs via hook to add default routes due to Ubuntu initramfs DHCP bug ========="
mkdir -p "$c_zfs_mount_dir/usr/share/initramfs-tools/scripts/init-premount"
cat > "$c_zfs_mount_dir/usr/share/initramfs-tools/scripts/init-premount/static-route" <<'CONF'
#!/bin/sh
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}

case $1 in
prereqs)
    prereqs
    exit 0
    ;;
esac

. /scripts/functions
# Begin real processing below this line

configure_networking

ip route add 172.31.1.1/255.255.255.255 dev ens3
ip route add default via 172.31.1.1 dev ens3
CONF

chmod 755 "$c_zfs_mount_dir/usr/share/initramfs-tools/scripts/init-premount/static-route"

echo "======= update initramfs =========="
chroot_execute "update-initramfs -u -k all"

echo "======= update grub =========="
chroot_execute "update-grub"

echo "======= setting up zed =========="

chroot_execute "zfs set canmount=noauto $v_rpool_name"

echo "======= setting mountpoints =========="
chroot_execute "zfs set mountpoint=legacy $v_bpool_name/BOOT/ubuntu"
chroot_execute "echo $v_bpool_name/BOOT/ubuntu /boot zfs nodev,relatime,x-systemd.requires=zfs-mount.service,x-systemd.device-timeout=10 0 0 > /etc/fstab"

chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/log"
chroot_execute "echo $v_rpool_name/var/log /var/log zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/spool"
chroot_execute "echo $v_rpool_name/var/spool /var/spool zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy $v_rpool_name/var/tmp"
chroot_execute "echo $v_rpool_name/var/tmp /var/tmp zfs nodev,relatime 0 0 >> /etc/fstab"
chroot_execute "zfs set mountpoint=legacy $v_rpool_name/tmp"
chroot_execute "echo $v_rpool_name/tmp /tmp zfs nodev,relatime 0 0 >> /etc/fstab"

echo "========= add swap, if defined"
if [[ $v_swap_size -gt 0 ]]; then
  chroot_execute "echo /dev/zvol/$v_rpool_name/swap none swap discard 0 0 >> /etc/fstab"
fi

chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"

echo "======= unmounting filesystems and zfs pools =========="
unmount_and_export_fs

echo "======== setup complete, rebooting ==============="
reboot
