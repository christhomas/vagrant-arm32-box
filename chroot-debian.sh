#!/usr/bin/env bash
#
# chroot-debian.sh — Customize a Debian rootfs for Vagrant/QEMU
#
# This script runs INSIDE a chroot of the Debian filesystem.
# It expects to be called via: chroot <mount-point> /path/to/chroot-debian.sh
#
# What it does:
#   - Creates vagrant user with passwordless sudo
#   - Configures SSH with Vagrant insecure keys
#   - Sets hostname and DHCP networking
#   - Installs growroot for first-boot disk expansion
#
set -e

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

info()  { echo "  [chroot] $*"; }

# ─── Vagrant user ────────────────────────────────────────────────────────────────

info "Creating vagrant user..."
if ! id vagrant &>/dev/null; then
    useradd -m -s /bin/bash -G sudo vagrant
fi
echo "vagrant:vagrant" | chpasswd

echo "vagrant ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vagrant
chmod 0440 /etc/sudoers.d/vagrant

# ─── SSH ─────────────────────────────────────────────────────────────────────────

info "Configuring SSH..."
mkdir -p /home/vagrant/.ssh
chmod 700 /home/vagrant/.ssh

cat > /home/vagrant/.ssh/authorized_keys <<'SSHKEYS'
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplJWTNSLQzpzSbEV9FNCPF+rIaQk5JKN20SdTz5Dt9U2aGe0y+1bt9Kbhq+c0yYjofkhqJXA7gQCMrDhRlGNz8W1p8OBBG+hEewVHGi+YL4AP8F1C9SaANEPpjE2L0t1L7Q1A5dSZUxnYt/JNsQ+y2GBnWH0YFUhgjLjFd8PkKJjLO5qEDVNSG9JkKIE2+6Y8oj8d0L2J0K1F3QRyJGC9XkSz3kC3jHGFdQJwmAA== vagrant insecure public key
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1YdxBpNlzxDqfJyw/QKow1F+wvG9hXGoqiysfJOn5Y vagrant insecure public key
SSHKEYS

chmod 600 /home/vagrant/.ssh/authorized_keys
chown -R vagrant:vagrant /home/vagrant/.ssh

systemctl enable ssh 2>/dev/null || true

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*UseDNS.*/UseDNS no/' /etc/ssh/sshd_config

info "Generating SSH host keys..."
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A

# ─── DHCP networking ────────────────────────────────────────────────────────────

info "Configuring DHCP networking..."
mkdir -p /etc/network/interfaces.d
cat > /etc/network/interfaces.d/eth0 <<'NETCFG'
auto eth0
iface eth0 inet dhcp
NETCFG

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-eth0.network <<'NETCFG'
[Match]
Name=eth0

[Network]
DHCP=yes
NETCFG

systemctl enable systemd-networkd 2>/dev/null || true

# ─── Growroot ────────────────────────────────────────────────────────────────────

info "Installing growroot service..."
cat > /etc/systemd/system/growroot.service <<'GROWSVC'
[Unit]
Description=Grow root partition to fill disk
ConditionPathExists=!/var/lib/growroot-done
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/growpart /dev/vda 1
ExecStart=/usr/sbin/resize2fs /dev/vda1
ExecStart=/usr/bin/touch /var/lib/growroot-done

[Install]
WantedBy=multi-user.target
GROWSVC

systemctl enable growroot.service 2>/dev/null || true

# ─── Cleanup ─────────────────────────────────────────────────────────────────────

info "Cleaning up..."
rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*
apt-get clean

dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
rm -f /EMPTY
sync

pkill -9 gpg-agent 2>/dev/null || true

info "Chroot customization complete."
