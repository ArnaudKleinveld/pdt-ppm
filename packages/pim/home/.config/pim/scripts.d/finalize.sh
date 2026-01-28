#!/bin/bash
# PIM Finalize Script
# Prepares the image for capture by cleaning up and resetting state
set -e

echo "=== PIM Image Finalization ==="

# Clean cloud-init state
echo "Cleaning cloud-init state..."
if command -v cloud-init &> /dev/null; then
    cloud-init clean --logs --seed || true
fi

# Remove SSH host keys (will be regenerated on first boot)
echo "Removing SSH host keys..."
rm -f /etc/ssh/ssh_host_*

# Configure SSH to regenerate keys on first boot
if [ -f /etc/rc.local ]; then
    if ! grep -q "ssh-keygen" /etc/rc.local; then
        sed -i '/^exit 0/d' /etc/rc.local
        cat >> /etc/rc.local <<'EOF'
# Regenerate SSH host keys if missing
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    dpkg-reconfigure openssh-server
fi
exit 0
EOF
    fi
fi

# Truncate machine-id (will be regenerated on first boot)
echo "Truncating machine-id..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Clean APT cache
echo "Cleaning APT cache..."
apt-get clean
apt-get autoremove -y || true
rm -rf /var/lib/apt/lists/*

# Clear logs
echo "Clearing logs..."
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.1" -delete
truncate -s 0 /var/log/wtmp || true
truncate -s 0 /var/log/lastlog || true

# Clear bash history
echo "Clearing bash history..."
for user_home in /root /home/*; do
    if [ -d "$user_home" ]; then
        rm -f "$user_home/.bash_history"
        rm -f "$user_home/.lesshst"
        rm -f "$user_home/.viminfo"
    fi
done

# Clear tmp directories
echo "Clearing temporary files..."
rm -rf /tmp/*
rm -rf /var/tmp/*

# Remove persistent network rules (will be regenerated)
echo "Removing persistent network rules..."
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f /etc/udev/rules.d/75-persistent-net-generator.rules

# Reset hostname to generic
echo "Resetting hostname..."
echo "localhost" > /etc/hostname

# Clear network interface configuration (let cloud-init handle it)
echo "Clearing network configuration..."
cat > /etc/network/interfaces <<'EOF'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback
EOF

# Remove any stale DHCP leases
rm -f /var/lib/dhcp/*.leases

# Sync filesystem
echo "Syncing filesystem..."
sync

# Zero out free space for better compression (optional, slow)
# Uncomment if you want smaller images
# echo "Zeroing free space (this may take a while)..."
# dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
# rm -f /EMPTY
# sync

echo "=== Finalization complete ==="
echo "Image is ready for capture."
