# ADR-001: PIM Build Architecture - Packer-Free Image Building

## Status

Proposed

## Date

2025-01-27

## Context

PIM (Product Image Manager) currently uses Packer as the image building engine, wrapping Packer HCL templates with Ruby orchestration. After analysis, we've determined that Packer adds complexity without providing significant value for our use case, since:

1. We exclusively build qcow2 as a universal intermediate format
2. We already have `pim serve` providing preseed/autoinstall configuration
3. QEMU can be invoked directly with equal capability
4. The Packer HCL templating layer adds cognitive overhead
5. Ansible is not needed for build-time provisioning (shell scripts via SSH suffice)

The new architecture simplifies the stack:

**Before:** ISO → Packer (HCL templates) → qcow2 → Post-processors → Targets
**After:** ISO → PIM (Ruby + QEMU) → qcow2 → PIM Deploy → Targets

## Decision

### Core Principles

1. **qcow2 as Universal Intermediate**: All builds produce qcow2 images with cloud-init installed
2. **No Packer**: PIM directly orchestrates QEMU for image building
3. **No Ansible at Build Time**: SSH + shell scripts handle provisioning
4. **Smart Architecture Routing**: Builds automatically route to appropriate builder based on host/target architecture
5. **Cloud-init for Deploy-time Configuration**: Images are generic; identity is applied at deployment
6. **OpenTofu for Deployment**: Stateful infrastructure management for target platforms

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           PIM BUILD PHASE                                │
│                                                                          │
│  pim build [PROFILE]                                                     │
│  ├── Resolve profile (iso + profile + scripts)                          │
│  ├── Select builder (local or remote based on architecture)             │
│  ├── Start QEMU with ISO                                                 │
│  ├── pim serve provides preseed/autoinstall                             │
│  ├── Wait for SSH availability (poll)                                    │
│  ├── SSH provision (execute shell scripts)                               │
│  ├── Finalize (cloud-init clean, truncate machine-id)                   │
│  ├── Shutdown VM                                                         │
│  └── Output: tagged qcow2 in cache                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                           qcow2 artifact
                      (generic, cloud-init ready)
                                    │
┌─────────────────────────────────────────────────────────────────────────┐
│                          PIM DEPLOY PHASE                                │
│                                                                          │
│  pim deploy [IMAGE] --target [TARGET]                                    │
│  ├── Convert format if needed (qcow2 → raw for AWS)                     │
│  ├── Upload to target storage                                            │
│  ├── Register as template/AMI                                            │
│  └── Output: Image reference (AMI ID, template name, etc.)              │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         TOFU PROVISION PHASE                             │
│                                                                          │
│  tofu apply                                                              │
│  ├── Reference deployed image                                            │
│  ├── Create instances/VMs                                                │
│  ├── Provide cloud-init user-data (hostname, users, keys)               │
│  └── Output: Instance IPs in state                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        ANSIBLE DAY-2 PHASE                               │
│                                                                          │
│  ansible-playbook -i inventory playbook.yml                              │
│  ├── Inventory from tofu output or dynamic                               │
│  ├── Application deployment                                              │
│  ├── Configuration updates                                               │
│  └── Ongoing maintenance                                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | State |
|-----------|---------------|-------|
| `pim build` | Create qcow2 images | qcow2 files in cache |
| `pim deploy` | Upload/convert images to targets | Image metadata in pim registry |
| `tofu` | Provision infrastructure | terraform.tfstate |
| `ansible` | Day-2 operations | Stateless |

### Smart Architecture Routing

PIM will automatically select the appropriate builder based on host and target architecture:

```
┌─────────────────┬──────────────────┬─────────────────────────────────┐
│ Host            │ Target           │ Builder Selection               │
├─────────────────┼──────────────────┼─────────────────────────────────┤
│ Mac M-series    │ arm64            │ Local (HVF acceleration)        │
│ Mac M-series    │ x86_64           │ Remote (Proxmox with KVM)       │
│ Mac Intel       │ x86_64           │ Local (HVF acceleration)        │
│ Mac Intel       │ arm64            │ Remote (if available)           │
│ Linux x86_64    │ x86_64           │ Local (KVM acceleration)        │
│ Linux x86_64    │ arm64            │ Remote (if available)           │
│ Linux arm64     │ arm64            │ Local (KVM acceleration)        │
│ Linux arm64     │ x86_64           │ Remote (if available)           │
└─────────────────┴──────────────────┴─────────────────────────────────┘
```

Configuration for builders:

```yaml
# ~/.config/pim/pim.yml
build:
  builders:
    arm64: local
    x86_64: proxmox-sg
  
  remotes:
    proxmox-sg:
      type: ssh
      host: proxmox-sg.lab.local
      user: root
      # PIM will SSH to this host and run the build there
```

### Image Tagging and Registry

Built images are tagged with metadata for consumption by tofu and ansible:

```yaml
# ~/.local/share/pim/registry.yml
images:
  developer:
    arm64:
      path: ~/.local/share/pim/cache/images/developer-arm64-abc123.qcow2
      built_at: 2025-01-27T10:00:00Z
      cache_key: abc123
      profile: developer
      iso: debian-13.3.0-arm64-netinst
    x86_64:
      path: ~/.local/share/pim/cache/images/developer-x86_64-def456.qcow2
      built_at: 2025-01-27T10:30:00Z
      cache_key: def456

deployments:
  developer:
    proxmox-sg:
      type: template
      template_id: 9000
      deployed_at: 2025-01-27T11:00:00Z
      image_cache_key: def456
    aws-sg:
      type: ami
      ami_id: ami-abc123
      deployed_at: 2025-01-27T11:30:00Z
      image_cache_key: def456
```

### Directory Structure Changes

```
~/.config/pim/
├── pim.yml                   # Runtime config (add build.builders, build.remotes)
├── isos.d/                   # ISO catalog (unchanged)
├── profiles.d/               # Installation profiles (unchanged)  
├── targets.d/                # Deploy targets (simplified, post-processors only)
├── preseeds.d/               # Preseed templates (unchanged)
├── installs.d/               # Post-install scripts (unchanged)
├── scripts.d/                # NEW: SSH provisioning scripts
│   ├── base.sh              # Common setup (cloud-init, cleanup)
│   ├── developer.sh         # Developer tools
│   └── k8s-node.sh          # Kubernetes node setup
└── templates/                # REMOVED: No more Packer templates

~/.local/share/pim/
├── cache/
│   └── images/              # Built qcow2 images (tagged by cache key)
└── registry.yml             # NEW: Image and deployment tracking

~/.cache/pim/
├── isos/                    # Downloaded ISOs (unchanged)
└── builds/                  # REMOVED: Consolidated into share/pim/cache
```

### SSH Provisioning Scripts

Scripts follow a modular pattern:

```bash
# scripts.d/base.sh - Always runs, sets up cloud-init
#!/bin/bash
set -euo pipefail

# Install cloud-init
apt-get update
apt-get install -y cloud-init

# Enable cloud-init services
systemctl enable cloud-init-local cloud-init cloud-config cloud-final

# Clean up for templating
cloud-init clean --logs
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*

echo "Base provisioning complete"
```

```bash
# scripts.d/developer.sh - Developer workstation profile
#!/bin/bash
set -euo pipefail

# Source base setup
# Note: base.sh runs separately, this is additive

apt-get install -y \
  build-essential \
  git \
  vim \
  tmux \
  zsh \
  htop \
  curl \
  wget

echo "Developer provisioning complete"
```

### Configuration Schema Changes

#### Profile Schema (profiles.d/*.yml)

```yaml
# profiles.d/developer.yml
developer:
  # Preseed/autoinstall settings (unchanged)
  username: admin
  password: changeme
  hostname: developer
  timezone: UTC
  packages: openssh-server curl sudo

  # NEW: Provisioning scripts to run via SSH
  scripts:
    - base        # Always include base
    - developer   # Profile-specific

  # NEW: Architecture (determines ISO selection and builder)
  architectures:
    - arm64
    - x86_64
```

#### Target Schema (targets.d/*.yml)

Simplified to only contain deployment/post-processor configuration:

```yaml
# targets.d/proxmox-sg.yml
proxmox-sg:
  type: proxmox
  host: proxmox-sg.lab.local
  node: pve1
  storage: local-lvm
  cloud_init_storage: local
  template_id_start: 9000

# targets.d/aws-sg.yml
aws-sg:
  type: aws
  region: ap-southeast-1
  s3_bucket: pim-images-sg
  
# targets.d/utm.yml
utm:
  type: utm
  output_dir: ~/.local/share/pim/utm
```

### Build Flow Detail

```ruby
# Pseudocode for pim build flow

def build(profile_name, arch: nil)
  # 1. Load and resolve profile
  profile = resolve_profile(profile_name)
  arch ||= detect_target_architecture(profile)
  
  # 2. Select builder based on host/target arch
  builder = select_builder(arch)
  
  # 3. Check cache
  cache_key = compute_cache_key(profile, arch)
  return cached_image(cache_key) if cache_hit?(cache_key) && !force_rebuild?
  
  # 4. Resolve ISO for architecture
  iso = resolve_iso(profile, arch)
  ensure_iso_downloaded(iso)
  
  # 5. Build (local or remote)
  if builder.local?
    build_local(profile, iso, arch, cache_key)
  else
    build_remote(builder.remote, profile, iso, arch, cache_key)
  end
  
  # 6. Register in image registry
  register_image(profile_name, arch, cache_key)
end

def build_local(profile, iso, arch, cache_key)
  output_path = cache_path(cache_key)
  
  # Create disk image
  create_disk_image(output_path, profile.disk_size)
  
  # Start preseed server in background
  server = start_preseed_server(profile)
  
  # Start QEMU
  qemu = start_qemu(
    iso: iso.path,
    disk: output_path,
    arch: arch,
    memory: profile.build_memory,
    cpus: profile.build_cpus,
    preseed_url: server.preseed_url
  )
  
  # Wait for installation to complete and SSH to become available
  wait_for_ssh(qemu.ip, timeout: 1800)
  
  # Run provisioning scripts via SSH
  ssh_provision(qemu.ip, profile.scripts)
  
  # Finalize
  ssh_exec(qemu.ip, "cloud-init clean --logs")
  ssh_exec(qemu.ip, "truncate -s 0 /etc/machine-id")
  ssh_exec(qemu.ip, "poweroff")
  
  # Wait for QEMU to exit
  qemu.wait
  
  # Stop preseed server
  server.stop
  
  output_path
end
```

## Consequences

### Positive

1. **Simplified Stack**: No Packer, no HCL templates, no Ansible at build time
2. **Unified Tooling**: All build logic in Ruby, easier to debug and extend
3. **Faster Iteration**: Direct QEMU control, no Packer abstraction layer
4. **Better Caching**: PIM controls caching logic directly
5. **Clearer Separation**: Build (PIM) → Deploy (PIM) → Provision (Tofu) → Maintain (Ansible)
6. **Cross-Architecture Support**: Smart routing handles Mac ARM to x86 target builds

### Negative

1. **More Code in PIM**: We're taking on responsibility Packer previously handled
2. **QEMU Expertise Required**: Need to understand QEMU flags and behaviors
3. **Remote Build Complexity**: SSH-based remote builds add complexity
4. **Testing Burden**: Must test across multiple host/target architecture combinations

### Neutral

1. **Learning Curve**: Different mental model from Packer, but arguably simpler
2. **Migration Effort**: Existing builds.d configs need updating

## Alternatives Considered

### Keep Packer, Remove Ansible

Rejected because Packer still adds HCL complexity and the builder abstraction isn't needed when we only target qcow2.

### Use virt-builder / virt-customize

Could simplify some aspects but less flexible than direct QEMU control and less portable across host platforms.

### Use cloud-init only (no SSH provisioning)

Rejected because cloud-init's `runcmd` is limited compared to full shell scripts, and SSH provisioning allows interactive debugging during development.

## References

- [QEMU Documentation](https://www.qemu.org/docs/master/)
- [cloud-init Documentation](https://cloud-init.io/)
- [OpenTofu Documentation](https://opentofu.org/docs/)
- [Debian Preseed Documentation](https://www.debian.org/releases/stable/amd64/apb.en.html)
- [Ubuntu Autoinstall Reference](https://ubuntu.com/server/docs/install/autoinstall-reference)
