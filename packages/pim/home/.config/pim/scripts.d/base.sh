#!/bin/bash
# PIM Base Provisioning Script
# Sets up cloud-init and basic system configuration for VM images
set -e

echo "=== PIM Base Provisioning ==="

# Update package lists
echo "Updating package lists..."
apt-get update

# Install cloud-init and essential packages
echo "Installing cloud-init and essential packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cloud-init \
    cloud-utils \
    cloud-guest-utils \
    qemu-guest-agent \
    acpid \
    curl \
    ca-certificates \
    gnupg \
    lsb-release

# Enable and start qemu-guest-agent
echo "Enabling qemu-guest-agent..."
systemctl enable qemu-guest-agent || true
systemctl start qemu-guest-agent || true

# Enable acpid for graceful shutdown
echo "Enabling acpid..."
systemctl enable acpid || true
systemctl start acpid || true

# Configure cloud-init datasources
echo "Configuring cloud-init datasources..."
cat > /etc/cloud/cloud.cfg.d/90_dpkg.cfg <<'EOF'
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Ec2, GCE, Azure, None ]
EOF

# Configure cloud-init to preserve hostname
cat > /etc/cloud/cloud.cfg.d/99_pim.cfg <<'EOF'
# PIM cloud-init configuration
preserve_hostname: false
manage_etc_hosts: true

# Disable some modules that can cause issues
cloud_init_modules:
 - migrator
 - seed_random
 - bootcmd
 - write-files
 - growpart
 - resizefs
 - disk_setup
 - mounts
 - set_hostname
 - update_hostname
 - update_etc_hosts
 - ca-certs
 - rsyslog
 - users-groups
 - ssh

cloud_config_modules:
 - emit_upstart
 - ssh-import-id
 - locale
 - set-passwords
 - grub-dpkg
 - apt-configure
 - ntp
 - timezone
 - disable-ec2-metadata
 - runcmd

cloud_final_modules:
 - package-update-upgrade-install
 - scripts-vendor
 - scripts-per-once
 - scripts-per-boot
 - scripts-per-instance
 - scripts-user
 - ssh-authkey-fingerprints
 - keys-to-console
 - phone-home
 - final-message
 - power-state-change
EOF

# Configure default user (will be overridden by cloud-init on first boot)
echo "Configuring default user for cloud-init..."
cat > /etc/cloud/cloud.cfg.d/99_default_user.cfg <<'EOF'
system_info:
  default_user:
    name: ansible
    lock_passwd: false
    gecos: Ansible User
    groups: [adm, cdrom, dip, plugdev, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
EOF

# Ensure growpart can expand the root filesystem
echo "Configuring growpart..."
cat > /etc/cloud/cloud.cfg.d/99_growpart.cfg <<'EOF'
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
EOF

# Configure SSH for cloud environments
echo "Configuring SSH..."
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Enable SSH on boot
systemctl enable ssh || systemctl enable sshd || true

# Clean up APT cache
echo "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "=== Base provisioning complete ==="
