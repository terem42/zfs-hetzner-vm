#!/bin/bash

apt update
apt install --yes dpkg-dev dkms linux-headers-generic linux-image-generic
rm "$(which zfs)"
export PATH=$PATH:/usr/sbin
echo -e "deb http://deb.debian.org/debian/ testing main contrib non-free\ndeb http://deb.debian.org/debian/ testing main contrib non-free\n" >/etc/apt/sources.list.d/bookworm-testing.list
echo -e "Package: src:zfs-linux\nPin: release n=testing\nPin-Priority: 990\n" > /etc/apt/preferences.d/90_zfs
apt update
apt install -t testing zfs-dkms zfsutils-linux
rm /etc/apt/sources.list.d/bookworm-testing.list
rm /etc/apt/preferences.d/90_zfs
apt update

