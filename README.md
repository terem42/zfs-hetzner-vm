# zfs-hetzner-vm

[![shellcheck](https://github.com/terem42/zfs-hetzner-vm/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/terem42/zfs-hetzner-vm/actions/workflows/shellcheck.yml)

Scripts to install Debian 10, 11, 12 or Ubuntu 18 LTS, 20 LTS, 22 LTS with ZFS root on Hetzner root servers (virtual and dedicated).<br/>
__WARNING:__ all data on the disk will be destroyed.

## How to use:

* Login into Hetzner cloud server console.
* Choose "rescue" menu.
* Click "enable rescue and power cycle",  add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power cycle" button.
* connect via SSH to rescue console, and run the script from this repo.

Debian 10 minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-debian10-zfs-setup.sh | bash -
````

Debian 11 minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-debian11-zfs-setup.sh | bash -
````

Debian 12 minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-debian12-zfs-setup.sh | bash -
````

Ubuntu 18.04 LTS minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-ubuntu18-zfs-setup.sh | bash -
````

Ubuntu 20 LTS minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-ubuntu20-zfs-setup.sh | bash -
````

Ubuntu 22 LTS minimal setup with SSH server

````bash
wget -qO- https://raw.githubusercontent.com/terem42/zfs-hetzner-vm/master/hetzner-ubuntu22-zfs-setup.sh | bash -
````

Answer script questions about desired hostname and ZFS ARC cache size.

To cope with network failures its higly recommended to run the commands above inside screen console, type `man screen` for more info.
Example of screen utility usage:

````bash
export LC_ALL=en_US.UTF-8 && screen -S zfs
````
To detach from screen console, hit Ctrl-d then a
To reattach, type `screen -r zfs`

Upon succesfull run, the script will reboot system, and you will be able to login into it, using the same SSH key you have used within rescue console

Please note that the drives you intend to format can not be in use,
you can execute `mdadm --stop --scan` before running the script to halt default software raid operations.
