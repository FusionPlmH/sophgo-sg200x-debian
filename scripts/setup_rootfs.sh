#!/bin/sh
#
set -ex

BOARD=$(cat /tmp/install/board)
HOSTNAME=$(cat /tmp/install/hostname)
STORAGETYPE=$(cat /tmp/install/storage)


export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
export LC_ALL=C LANGUAGE=C LANG=C

/var/lib/dpkg/info/base-passwd.preinst install || true
/var/lib/dpkg/info/sgml-base.preinst install || true

mkdir -p /etc/sgml
mount proc -t proc /proc
mount -B sys /sys
mount -B run /run
mount -B dev /dev
#mount devpts -t devpts /dev/pts
dpkg --configure -a

unset DEBIAN_FRONTEND DEBCONF_NONINTERACTIVE_SEEN

# Set root passwd
echo "root:debian" | chpasswd

# Set up fstab
cat > /etc/fstab <<EOF
# <file system> <mount point>   <type>  <options>                 <dump>  <pass>
/dev/root       /               auto    defaults                  1       1
EOF

if [ "$STORAGETYPE" = "sd" ]; then
  cat >> /etc/fstab <<EOF
/dev/mmcblk0p1  /boot           auto    defaults                  1       2
EOF
fi



#regenerate SSH keys on first boot
cat > /etc/systemd/system/finalize-image.service <<EOF
[Unit]
Description=Finalize the Image
Before=ssh.service

[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/parted -s -f /dev/mmcblk0 resizepart 2 100%
ExecStartPre=-/usr/sbin/resize2fs /dev/mmcblk0p2
ExecStartPre=-/bin/dd if=/dev/hwrng of=/dev/urandom count=1 bs=4096
ExecStartPre=-/bin/sh -c "/bin/rm -f -v /etc/ssh/ssh_host_*_key*"
ExecStartPre=/sbin/swapon /swapfile
ExecStartPost=/bin/systemctl disable finalize-image

[Install]
WantedBy=multi-user.target
EOF

if [ "$STORAGETYPE" = "emmc" ]; then
sed -i -e 's|ExecStartPre=-/usr/sbin/parted -s -f /dev/mmcblk0 resizepart 2 100%|ExecStartPre=-/usr/sbin/parted -s -f /dev/mmcblk0 resizepart 1 100%|' /etc/systemd/system/finalize-image.service
fi

cat /etc/systemd/system/finalize-image.service

apt-get --no-install-recommends --no-install-suggests install -y -f /tmp/install/*.deb


# change device tree
echo "===== ln -s dtb files ====="
file_prefix="/usr/lib/linux-image-*"

file_path=$(ls -d $file_prefix)

if [ -e "$file_path" ]; then
  echo "File found: $file_path"
  lib_dir=$file_path
else
  echo "File not found: $file_path"
fi

kernel_image=${lib_dir##*/}

# set default dtb file, please verify your board version
mkdir -p /boot/fdt/${kernel_image}

cp ${lib_dir}/cvitek/*.dtb /boot/fdt/${kernel_image}/


cat /boot/extlinux/extlinux.conf

if [ "$STORAGETYPE" = "sd" ]; then
sed -i -i 's|#U_BOOT_PARAMETERS=".*"|U_BOOT_PARAMETERS="console=ttyS0,115200 earlycon=sbi root=/dev/mmcblk0p2 rootwait rw"|' /etc/default/u-boot
else
sed -i -i 's|#U_BOOT_PARAMETERS=".*"|U_BOOT_PARAMETERS="console=ttyS0,115200 earlycon=sbi root=/dev/mmcblk0p1 rootwait rw"|' /etc/default/u-boot
fi

sed -i -e 's|#U_BOOT_SYNC_DTBS=".*"|U_BOOT_SYNC_DTBS="true"|' /etc/default/u-boot
#doing this dance, as in the chroot, / and /boot are same filesystem, so u-boot-update doesn't setup correctly
echo "U_BOOT_FDT_DIR=\"/usr/lib/linux-image-$BOARD-\"" >> /etc/default/u-boot
u-boot-update
if [ "$STORAGETYPE" = "sd" ]; then
  sed -i -e 's|fdtdir /usr/lib/|fdtdir /fdt/|' /boot/extlinux/extlinux.conf
  sed -i -e 's|linux /boot/|linux /|' /boot/extlinux/extlinux.conf
  sed -i -e "s|U_BOOT_FDT_DIR=\".*\"|U_BOOT_FDT_DIR=\"/fdt/linux-image-$BOARD-\"|" /etc/default/u-boot
else 
  sed -i -e 's|fdtdir /usr/lib/|fdtdir /boot/fdt/|' /boot/extlinux/extlinux.conf
fi

cat /boot/extlinux/extlinux.conf

# Set hostname
cat /tmp/install/hostname > /etc/hostname

# 
cat >> /etc/hosts << EOF
127.0.0.1      ${HOSTNAME} 
EOF


cat >> /etc/network/interfaces.d/usb0 << EOF
auto usb0
iface usb0 inet static
        address 10.42.0.1
        netmask 255.255.255.0
EOF


cat >> /etc/wpa_supplicant/wpa_supplicant.conf << EOF
network={
    ssid="Home_5G"
    psk="13password"
}
EOF


# 
# Disable Log for better performance save space
#
systemctl stop systemd-journald-dev-log.socket
systemctl stop systemd-journald.socket
systemctl stop systemd-journald
systemctl mask systemd-journald.service
systemctl mask systemd-journald.socket
systemctl mask systemd-journald-dev-log.socket

cat >> /etc/sysctl.conf << EOF
kernel.printk = 3 4 1 3
vm.swappiness=10
vm.dirty_ratio = 10
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF

sysctl -p

cat >> /etc/network/interfaces.d/wlan0 << EOF
allow-hotplug wlan0
iface wlan0 inet static
        address 192.168.31.67
        netmask 255.255.255.0
        gateway 192.168.31.1
EOF



cat > /etc/systemd/system/wpa_supplicant@wlan0.service <<EOF
[Unit]
Description=WPA Supplicant for wlan0
After=network.target
Wants=network-online.target

[Service]
ExecStart=/sbin/wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF


### Step 3: Enable the WPA Supplicant Service
systemctl enable wpa_supplicant@wlan0.service

# 
# Enable system services
#
systemctl enable finalize-image.service
if [ -f /tmp/install/systemd-enable ]; then
  systemctl enable `cat /tmp/install/systemd-enable`
fi

# Update source list 

rm -rf /etc/apt/sources.list.d/multistrap-debian.list

cp /tmp/install/public-key.asc /etc/apt/trusted.gpg.d/sophgo-myho-st.gpg

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian sid main non-free-firmware
deb https://sophgo.my-ho.st:8443/ debian sophgo
EOF

echo "/boot/uboot.env	0x0000          0x20000" > /etc/fw_env.config
mkenvimage -s 0x20000 -o /boot/uboot.env /etc/u-boot-initial-env

# Create Swap
dd if=/dev/zero of=/swapfile bs=1G count=2
chmod 600 /swapfile
mkswap /swapfile

cat >> /etc/fstab << EOF
/swapfile       none            swap    sw                        0       0
EOF




# Add custom support
rm -rf /etc/resolv.conf
rm -rf /usr/lib/systemd/resolv.conf
cat > "/etc/resolv.conf" <<-EOF
nameserver 1.1.1.1
mameserver 8.8.8.8
EOF
cat > "/usr/lib/systemd/resolv.conf" <<-EOF
nameserver 1.1.1.1
mameserver 8.8.8.8
EOF

#
# Clean apt cache on the system
#
apt-get clean


rm -rf /var/cache/*
find /var/lib/apt/lists -type f -not -name '*.gpg' -print0 | xargs -0 rm -f
find /var/log -type f -print0 | xargs -0 truncate --size=0
