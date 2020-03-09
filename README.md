# zfs-hetzner-vm

Scripts to install Debian 10 or Ubuntu 18 with ZFS root on Hetzner root servers (virtual and dedicated).<br/>
__WARNING:__ all data on the disk will be destroyed.

## How to use:

* Login into Hetzner cloud server console.
* Choose "rescue" menu.
* Click "enable rescue and power cycle",  add SSH key to the rescue console, set it OS to linux64, then press mount rescue and power cycle" button.
* connect via SSH to rescue console, and run the script from this repo.

Debian 10 minimal setup with SSH server

````
wget -qO- https://raw.githubusercontent.com/andrey42/zfs-hetzner-vm/master/hetzner-debian10-zfs-setup.sh | bash -
````

Ubuntu 18.04 LTS minimal setup with SSH server

````
wget -qO- https://raw.githubusercontent.com/andrey42/zfs-hetzner-vm/master/hetzner-ubuntu18-zfs-setup.sh | bash -
````

Answer script questions about desired hostname and ZFS ARC cache size.

To cope with network failures its higly recommended to run the commands above inside screen console, type `man screen` for more info.
Example of screen utility usage:
````
screen -S zfs
````
To detach from screen console, hit Ctrl-d then a
To reattach, type `screen -r zfs`

Upon succesfull run, the script will reboot system, and you will be able to login into it, using the same SSH key you have used within rescue console

