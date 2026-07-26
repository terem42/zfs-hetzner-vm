# zfs-hetzner-vm

[![shellcheck](https://github.com/terem42/zfs-hetzner-vm/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/terem42/zfs-hetzner-vm/actions/workflows/shellcheck.yml)

Scripts to install Debian 12, 13 or Ubuntu 22 LTS, 24 LTS with ZFS root on Hetzner root servers (virtual and dedicated).
__WARNING:__ all data on the disk will be destroyed.

Scripts for end-of-life releases (Debian 10, 11 and Ubuntu 18, 20) have been removed, as fresh installs of unsupported releases receive no security updates. If you really need one, they remain available in the git history.

## Features

* **ZFSBootMenu bootloader** (v3.1.0) instead of GRUB: the kernel and initramfs live on the ZFS pool itself, so there is no crippled GRUB-compatible boot pool. Boot environments, snapshot rollback and clone-and-boot are available straight from the boot menu, and `zpool upgrade` cannot break booting.
* **BIOS and UEFI support**, auto-detected (ZFSBootMenu via extlinux on BIOS, EFI binary on UEFI).
* **Optional ZFS native encryption** (aes-256-gcm) for the whole pool, set up per the ZFSBootMenu docs: the passphrase is entered once per boot at the ZFSBootMenu prompt via the Hetzner server console; the second unlock by the OS initramfs is automatic via an embedded key file.
* **Single-pool dataset layout** with separate datasets for `/home`, `/var/log`, `/tmp`, `/var/tmp` and `/var/cache/apt`, lz4 compression, and a user-configurable ARC size limit.
* **Newest ZFS the release can support**: Debian installs ZFS from backports (2.4.x on Debian 13, 2.3.x on Debian 12); on Ubuntu 22 the pool is created with `compatibility=openzfs-2.1-linux` so it stays importable by jammy's ZFS 2.1.
* **SSH hardening from the first boot**: your rescue-console SSH key is installed for root, password authentication is disabled, and fresh host keys are generated.
* **Hetzner-aware defaults**: Hetzner package mirrors for fast installs, DHCP networking via systemd-networkd (netplan on Ubuntu), cloud kernel variants where available.
* Interactive whiptail dialogs for hostname, pool name, root password, optional encryption passphrase and ARC size, with a final confirmation summary before the disk is touched.

## How to use:

* Login into Hetzner cloud server console.
* Choose "rescue" menu.
* Click "enable rescue and power cycle",  add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power cycle" button.
* connect via SSH to rescue console, and run the script from this repo.

Debian 12 minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-debian12-zfs-setup.sh | bash -
````

Debian 13 minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-debian13-zfs-setup.sh | bash -
````

Ubuntu 22 LTS minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-ubuntu22-zfs-setup.sh | bash -
````

Ubuntu 24 LTS minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-ubuntu24-zfs-setup.sh | bash -
````

Answer the script questions about hostname, ZFS pool name, root password, optional pool encryption and ZFS ARC cache size, then confirm the summary screen.

If you enable encryption, keep the Hetzner server console handy: every boot stops at the ZFSBootMenu prompt until you enter the pool passphrase there.

To cope with network failures its highly recommended to run the commands above inside screen console, type `man screen` for more info.
Example of screen utility usage:

````bash
export LC_ALL=en_US.UTF-8 && screen -S zfs
````
To detach from screen console, hit Ctrl-a then d
To reattach, type `screen -r zfs`

Upon successful run, the script will reboot the system, and you will be able to login into it, using the same SSH key you have used within rescue console

Please note that the drives you intend to format can not be in use,
you can execute `mdadm --stop --scan` before running the script to halt default software raid operations.
