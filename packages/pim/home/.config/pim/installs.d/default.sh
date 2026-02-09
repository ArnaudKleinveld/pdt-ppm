#!/bin/bash
exec > /root/install.log 2>&1
set -ex

# Post-installation script for default profile
# This script runs after the base system is installed via preseed late_command
echo "=== Post-installation script starting ==="
# Add custom post-installation commands here

export DEBIAN_FRONTEND=noninteractive
apt-get update || true
# apt-get install -y zsh htop

cat > /home/ansible/ppm.sh << 'EOF'
export PPM_SSH_AUTHORIZED_KEYS_URL=https://github.com/rjayroach.keys
export PPM_INSTALL_REPO=git@github.com:maxcole/rjayroach-ppm
export PPM_INSTALL_PACKAGES="chorus ruby-tools claude git nvim ssh tmux zsh"
curl -fsSL https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh | bash
EOF

chown ansible:ansible /home/ansible/ppm.sh
chmod +x /home/ansible/ppm.sh

echo "=== Post-installation complete ==="
