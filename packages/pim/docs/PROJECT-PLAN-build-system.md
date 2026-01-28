# PIM Build System Implementation Plan

## Project Overview

Implement a Packer-free image building system for PIM that directly orchestrates QEMU, uses SSH for provisioning, produces cloud-init ready qcow2 images, and supports smart architecture-based builder routing.

**Reference:** See `docs/ADR-001-pim-build-architecture.md` for architectural decisions.

## Prerequisites

Before starting implementation, ensure:

1. QEMU is installed (`brew install qemu` on macOS)
2. Ruby 3.x with gems: `thor`, `net-ssh`, `net-scp`
3. Access to test ISOs (Debian ARM64 for local Mac testing)
4. Understanding of existing PIM codebase structure

## CRITICAL: Leverage Existing Code

**DO NOT REWRITE** the following existing infrastructure. The new build system must integrate with and extend these existing modules:

| Existing Component | Location | How to Use |
|-------------------|----------|------------|
| `PimIso::Config` | `pim/iso.rb` | Load ISO catalog, get `iso_dir` |
| `PimIso::Manager` | `pim/iso.rb` | Download ISOs, verify checksums |
| `PimProfile::Config` | `pim/profile.rb` | Load profiles with deep merge |
| `Pim::Profile` | `pim` (main bin) | Resolve preseed/install templates |
| `Pim::Server` | `pim` (main bin) | Serve preseed.cfg and install.sh |
| `Pim::Config` | `pim` (main bin) | Load runtime configuration |

### What Already Works

1. **ISO Management** - `pim iso download`, verification, catalog
2. **Profile Loading** - Deep merge of default + named profile
3. **Template Resolution** - `profile.preseed_template`, `profile.install_template`
4. **Preseed Server** - WEBrick serving preseed.cfg and install.sh with ERB rendering

### What Needs to Be Added (Not Replaced)

1. **ISO**: Add `find_by_arch(arch)` method to find ISO matching architecture
2. **Profile**: Extend schema with `scripts`, `architectures`, `build` sections
3. **Server**: Wrap in background thread runner for build orchestration
4. **NEW**: QEMU orchestration, SSH provisioning, build manager, registry

---

## CRITICAL: Follow Existing Patterns

### Pattern 1: Default Config Deep Merge

All config types use a `default` entry that merges into named entries. See `PimProfile::Config#profile(name)` for the pattern:

```ruby
def profile(name)
  default_profile = @profiles['default'] || {}
  if name == 'default' || name.empty?
    default_profile
  else
    DeepMerge.merge(default_profile, @profiles[name] || {})
  end
end
```

**Any new config types (e.g., scripts, build settings) MUST follow this pattern.**

### Pattern 2: Naming Conventions with Fallback

Templates/scripts match profile name with fallback to `default`:

| Profile | First Try | Fallback |
|---------|-----------|----------|
| `developer` | `developer.cfg.erb` | `default.cfg.erb` |
| `k8s-node` | `k8s-node.sh` | `default.sh` |

See `Pim::Profile#preseed_template` and `#install_template` for implementation.

**New `scripts.d/` MUST follow the same convention.**

### Pattern 3: MANDATORY - Use Existing Pim::Server

**`pim build` MUST use the existing `Pim::Server` class.** Do not create a new HTTP server.

```ruby
# CORRECT: Wrap existing server in background thread
server = Pim::Server.new(
  profile: profile,
  port: find_available_port,
  preseed_name: profile_name,
  install_name: profile_name
)
thread = Thread.new { server.start }

# Use the URLs it provides
preseed_url = "http://#{host_ip}:#{port}/preseed.cfg"
```

The server already handles:
- ERB rendering of preseed templates
- Profile data binding
- Serving install scripts
- Network interface binding (not localhost)

---

## Implementation Phases

---

## Phase 1: Core Infrastructure

### 1.1 Create New Module Structure

**File:** `home/.local/lib/ruby/pim/build.rb`

Create the main build orchestration module with these classes:

```ruby
module PimBuild
  class Config          # Build configuration (builders, remotes)
  class Registry        # Image and deployment tracking
  class ArchitectureResolver  # Host/target arch detection and builder selection
  class CacheManager    # Image caching with content-based keys
  class CLI < Thor      # Command line interface
end
```

**Tasks:**
- [ ] Create `PimBuild::Config` class that loads build configuration from `pim.yml`
- [ ] Implement `build.builders` and `build.remotes` config sections
- [ ] Create `PimBuild::ArchitectureResolver` to detect host architecture
- [ ] Implement builder selection logic (local vs remote based on arch match)

**Config schema to support:**

```yaml
# pim.yml additions
build:
  # Default disk size for builds
  disk_size: 20G
  
  # Memory/CPU for build VMs
  memory: 2048
  cpus: 2
  
  # SSH settings for provisioning
  ssh:
    user: ansible          # Must match preseed username
    timeout: 1800          # 30 min timeout for install + SSH ready
    poll_interval: 10      # Seconds between SSH connection attempts
  
  # Architecture to builder mapping
  builders:
    arm64: local
    x86_64: proxmox-sg
  
  # Remote builder definitions
  remotes:
    proxmox-sg:
      type: ssh
      host: proxmox-sg.lab.local
      user: root
      pim_path: /usr/local/bin/pim   # Path to pim on remote
      cache_dir: /var/cache/pim      # Where to store images on remote
```

### 1.2 Create Image Registry

**File:** `home/.local/lib/ruby/pim/registry.rb`

```ruby
module PimRegistry
  class Registry
    # Tracks built images and deployments
    # Stored in ~/.local/share/pim/registry.yml
    
    def register_image(profile, arch, cache_key, path)
    def get_image(profile, arch)
    def register_deployment(profile, target, metadata)
    def get_deployment(profile, target)
    def list_images
    def list_deployments
  end
end
```

**Tasks:**
- [ ] Create Registry class with YAML persistence
- [ ] Implement image registration with metadata (built_at, cache_key, iso, profile)
- [ ] Implement deployment registration (target type, IDs, timestamps)
- [ ] Add methods to query images by profile/arch
- [ ] Add cleanup methods for orphaned entries

### 1.3 Create SSH Module

**File:** `home/.local/lib/ruby/pim/ssh.rb`

```ruby
module PimSSH
  class Connection
    def initialize(host, user:, port: 22, key: nil, forward_agent: false)
    def exec!(command, &block)     # Execute command, stream output
    def upload(local, remote)       # SCP upload
    def download(remote, local)     # SCP download
    def wait_for_ready(timeout:, interval:)  # Poll until SSH available
  end
  
  class KeyManager
    def build_keypair              # Generate temporary keypair for build
    def cleanup                    # Remove temporary keys
  end
end
```

**Tasks:**
- [ ] Create SSH wrapper using `net-ssh` gem
- [ ] Implement connection with timeout and retry logic
- [ ] Implement `wait_for_ready` that polls SSH port
- [ ] Add command execution with streaming output (for visibility during builds)
- [ ] Implement SCP upload/download
- [ ] Create temporary keypair generation for builds

---

## Phase 2: QEMU Orchestration

### 2.1 Create QEMU Module

**File:** `home/.local/lib/ruby/pim/qemu.rb`

```ruby
module PimQemu
  class DiskImage
    def self.create(path, size:, format: 'qcow2')
    def self.convert(source, dest, format:)
    def self.info(path)
  end
  
  class VM
    def initialize(arch:, disk:, iso: nil, memory: 2048, cpus: 2)
    def configure_network(mode: :user, hostfwd: [])
    def configure_display(mode: :none)
    def configure_boot(order: 'cd', kernel: nil, initrd: nil, append: nil)
    def start                      # Fork QEMU process
    def stop                       # Send shutdown via QMP or ACPI
    def wait                       # Wait for QEMU to exit
    def ip_address                 # Get VM IP (from user net or tap)
    def ssh_port                   # Get forwarded SSH port
    def running?
    
    private
    def qemu_binary                # qemu-system-aarch64 or qemu-system-x86_64
    def build_command_line
    def accelerator                # hvf, kvm, or tcg
  end
  
  class CommandBuilder
    # Builds QEMU command line arguments
    def self.for_arch(arch)
    def add_drive(path, format:, interface:)
    def add_cdrom(path)
    def add_network(mode:, hostfwd:)
    def add_display(mode:)
    def add_boot(order:)
    def add_kernel(kernel:, initrd:, append:)
    def to_command
  end
end
```

**Tasks:**
- [ ] Implement `DiskImage` class wrapping `qemu-img`
- [ ] Implement architecture-specific QEMU binary detection
- [ ] Implement accelerator detection (HVF on Mac, KVM on Linux, TCG fallback)
- [ ] Create `CommandBuilder` for constructing QEMU command lines
- [ ] Implement VM start with process forking
- [ ] Implement user-mode networking with port forwarding for SSH
- [ ] Implement VM shutdown (ACPI poweroff)
- [ ] Add IP/port detection for SSH connection

**QEMU command patterns:**

```bash
# ARM64 on Mac (HVF)
qemu-system-aarch64 \
  -M virt \
  -cpu host \
  -accel hvf \
  -m 2048 \
  -smp 2 \
  -drive file=disk.qcow2,format=qcow2,if=virtio \
  -cdrom debian.iso \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -display none \
  -serial mon:stdio \
  -boot d

# x86_64 on Linux (KVM)
qemu-system-x86_64 \
  -M q35 \
  -cpu host \
  -enable-kvm \
  -m 2048 \
  -smp 2 \
  -drive file=disk.qcow2,format=qcow2,if=virtio \
  -cdrom debian.iso \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -display none \
  -serial mon:stdio \
  -boot d
```

### 2.2 Preseed Server Integration

**Modify:** `home/.local/lib/ruby/pim/build.rb`

**MANDATORY:** The build system MUST use the existing `Pim::Server` class. Do not create a new HTTP server or reimplement template rendering.

The existing `Pim::Server` class (in the main `pim` bin file) already:
- Renders preseed templates with ERB using profile data
- Serves preseed.cfg at `/preseed.cfg`
- Serves install.sh at `/install.sh`  
- Uses profile name convention for template resolution (with fallback to default)
- Binds to correct network interface (not localhost)
- Handles the `install_url` variable injection into preseed template

**Tasks:**
- [ ] Create `PimBuild::PreseedServer` that wraps `Pim::Server` in a background thread
- [ ] The wrapper should NOT reimplement any server logic
- [ ] Add `find_available_port` helper method
- [ ] Add graceful shutdown (call `server.shutdown` via trap or explicit stop)

```ruby
module PimBuild
  class PreseedServer
    def initialize(profile:, profile_name:, port: nil)
      @port = port || find_available_port
      # Use the EXISTING Pim::Server class
      @server = Pim::Server.new(
        profile: profile,
        port: @port,
        preseed_name: profile_name,  # Follows naming convention
        install_name: profile_name   # Follows naming convention
      )
      @thread = nil
    end
    
    def start
      @thread = Thread.new { @server.start }
      sleep 0.5  # Give server time to bind
      self
    end
    
    def stop
      # Pim::Server uses WEBrick, which responds to shutdown
      @server.instance_variable_get(:@server)&.shutdown rescue nil
      @thread&.kill
    end
    
    def preseed_url
      "http://#{host_ip}:#{@port}/preseed.cfg"
    end
    
    def install_url
      "http://#{host_ip}:#{@port}/install.sh"
    end
    
    attr_reader :port
    
    private
    
    def host_ip
      # Same logic as Pim::Server#local_ip
      Socket.ip_address_list
            .detect { |addr| addr.ipv4? && !addr.ipv4_loopback? }
            &.ip_address || '127.0.0.1'
    end
    
    def find_available_port
      server = TCPServer.new('0.0.0.0', 0)
      port = server.addr[1]
      server.close
      port
    end
  end
end
```

---

## Phase 3: Build Orchestration

### 3.1 Local Builder

**File:** `home/.local/lib/ruby/pim/build/local_builder.rb`

```ruby
module PimBuild
  class LocalBuilder
    def initialize(profile:, iso:, arch:, config:)
    
    def build
      # 1. Create disk image
      # 2. Start preseed server
      # 3. Start QEMU with ISO boot
      # 4. Wait for SSH
      # 5. Run provisioning scripts
      # 6. Finalize (cloud-init clean, etc.)
      # 7. Shutdown
      # 8. Return path to qcow2
    end
    
    private
    def create_disk_image
    def start_preseed_server
    def start_qemu
    def wait_for_ssh
    def provision
    def finalize
    def shutdown
  end
end
```

**Tasks:**
- [ ] Implement complete local build flow
- [ ] Add progress output during each phase
- [ ] Handle errors gracefully (cleanup on failure)
- [ ] Support keyboard interrupt (Ctrl+C) for cancellation
- [ ] Add timeout handling for stuck builds
- [ ] Implement build logging to file

### 3.2 Remote Builder

**File:** `home/.local/lib/ruby/pim/build/remote_builder.rb`

```ruby
module PimBuild
  class RemoteBuilder
    def initialize(remote_config:, profile:, iso:, arch:, config:)
    
    def build
      # 1. SSH to remote host
      # 2. Ensure PIM is installed on remote
      # 3. Sync profile/preseed/scripts to remote
      # 4. Execute 'pim build --local' on remote
      # 5. Download resulting qcow2
      # 6. Cleanup remote artifacts
    end
    
    private
    def sync_config_to_remote
    def execute_remote_build
    def download_image
    def cleanup_remote
  end
end
```

**Tasks:**
- [ ] Implement remote build over SSH
- [ ] Sync necessary config files to remote
- [ ] Execute build command on remote
- [ ] Stream build output back to local terminal
- [ ] Download completed image
- [ ] Handle partial failures and cleanup

### 3.3 Build Manager

**File:** `home/.local/lib/ruby/pim/build/manager.rb`

```ruby
module PimBuild
  class Manager
    def initialize(project_dir: Dir.pwd)
    
    def build(profile_name, arch: nil, force: false)
      # 1. Resolve profile
      # 2. Determine architecture (auto-detect or specified)
      # 3. Compute cache key
      # 4. Check cache (unless force)
      # 5. Select builder (local or remote)
      # 6. Execute build
      # 7. Register in image registry
      # 8. Return image path
    end
    
    def list_images
    def show_image(profile, arch)
    def clean_cache(profile: nil, arch: nil)
    
    private
    def resolve_profile(name)
    def resolve_iso(profile, arch)
    def compute_cache_key(profile, arch)
    def select_builder(arch)
  end
end
```

**Tasks:**
- [ ] Implement build orchestration logic
- [ ] Add architecture auto-detection (prefer host arch)
- [ ] Implement cache key computation (hash of profile + preseed + scripts + iso)
- [ ] Add builder selection based on config
- [ ] Integrate with Registry for image tracking

---

## Phase 4: Scripts and Provisioning

### 4.1 Create Scripts Directory

**Directory:** `home/.config/pim/scripts.d/`

Create default provisioning scripts:

**File:** `scripts.d/base.sh`

```bash
#!/bin/bash
# Base provisioning - runs on all builds
# Installs cloud-init and prepares image for templating

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== PIM Base Provisioning ==="

# Update package lists
apt-get update

# Install cloud-init and dependencies
apt-get install -y \
  cloud-init \
  cloud-guest-utils \
  qemu-guest-agent

# Enable cloud-init services
systemctl enable cloud-init-local
systemctl enable cloud-init
systemctl enable cloud-config
systemctl enable cloud-final

# Enable qemu-guest-agent
systemctl enable qemu-guest-agent

# Configure cloud-init datasources
cat > /etc/cloud/cloud.cfg.d/99_pim.cfg << 'EOF'
# PIM cloud-init configuration
datasource_list: [ NoCloud, ConfigDrive, None ]
EOF

echo "=== Base provisioning complete ==="
```

**File:** `scripts.d/finalize.sh`

```bash
#!/bin/bash
# Finalize provisioning - runs last on all builds
# Cleans up image for templating

set -euo pipefail

echo "=== PIM Finalize ==="

# Clean cloud-init state
cloud-init clean --logs --seed

# Remove machine-id (regenerated on first boot)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Remove SSH host keys (regenerated on first boot)
rm -f /etc/ssh/ssh_host_*

# Clean apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clear logs
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f -exec truncate -s 0 {} \;

# Clear bash history
rm -f /root/.bash_history
rm -f /home/*/.bash_history

# Clear temporary files
rm -rf /tmp/*
rm -rf /var/tmp/*

echo "=== Finalize complete ==="
```

**File:** `scripts.d/developer.sh`

```bash
#!/bin/bash
# Developer profile provisioning

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== PIM Developer Provisioning ==="

apt-get update
apt-get install -y \
  build-essential \
  git \
  vim \
  neovim \
  tmux \
  zsh \
  htop \
  curl \
  wget \
  jq \
  unzip \
  tree \
  ripgrep \
  fd-find

echo "=== Developer provisioning complete ==="
```

**Tasks:**
- [ ] Create `scripts.d/base.sh` - cloud-init setup
- [ ] Create `scripts.d/finalize.sh` - image cleanup
- [ ] Create `scripts.d/developer.sh` - developer tools
- [ ] Create `scripts.d/k8s-node.sh` - Kubernetes prerequisites
- [ ] Create `scripts.d/docker.sh` - Docker installation

### 4.2 Script Loader

**File:** `home/.local/lib/ruby/pim/build/script_loader.rb`

**IMPORTANT:** Follow the same naming convention and fallback pattern as preseeds.d/ and installs.d/:
- Profile-specific script first: `scripts.d/{profile_name}.sh`
- Fallback to default: `scripts.d/default.sh`
- Search order: project directory, then global config directory

```ruby
module PimBuild
  class ScriptLoader
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    SCRIPTS_DIR = File.join(XDG_CONFIG_HOME, 'pim', 'scripts.d')
    
    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
    end
    
    # Load scripts for a profile
    # Returns array of script contents in execution order:
    # 1. base.sh (always first)
    # 2. profile-specific scripts (from profile.scripts array)
    # 3. finalize.sh (always last)
    def load_scripts(profile_name, additional_scripts: [])
      scripts = []
      
      # Always start with base
      scripts << load_script('base')
      
      # Profile-specific script (follows naming convention)
      profile_script = find_script(profile_name)
      scripts << { name: profile_name, path: profile_script, content: File.read(profile_script) } if profile_script
      
      # Additional scripts from profile config
      additional_scripts.each do |name|
        next if %w[base finalize].include?(name)  # Skip, handled separately
        next if name == profile_name  # Already loaded
        script = find_script(name)
        scripts << { name: name, path: script, content: File.read(script) } if script
      end
      
      # Always end with finalize
      scripts << load_script('finalize')
      
      scripts.compact
    end
    
    # Find script by name - follows same pattern as Pim::Profile#preseed_template
    def find_script(name)
      # 1. Project directory (profile-specific)
      project_path = File.join(@project_dir, 'scripts.d', "#{name}.sh")
      return project_path if File.exist?(project_path)
      
      # 2. Global config directory (profile-specific)
      global_path = File.join(SCRIPTS_DIR, "#{name}.sh")
      return global_path if File.exist?(global_path)
      
      # 3. Fallback to default (if not already looking for default)
      if name != 'default'
        default_project = File.join(@project_dir, 'scripts.d', 'default.sh')
        return default_project if File.exist?(default_project)
        
        default_global = File.join(SCRIPTS_DIR, 'default.sh')
        return default_global if File.exist?(default_global)
      end
      
      nil
    end
    
    def list_available
      scripts = []
      [File.join(@project_dir, 'scripts.d'), SCRIPTS_DIR].each do |dir|
        next unless Dir.exist?(dir)
        Dir.glob(File.join(dir, '*.sh')).each do |path|
          scripts << File.basename(path, '.sh')
        end
      end
      scripts.uniq.sort
    end
    
    private
    
    def load_script(name)
      path = find_script(name)
      return nil unless path
      { name: name, path: path, content: File.read(path) }
    end
  end
end
```

**Tasks:**
- [ ] Implement script discovery (project then global)
- [ ] Implement script ordering (base first, finalize last)
- [ ] Add script content loading
- [ ] Add validation (script exists, is executable)

---

## Phase 5: Profile Schema Updates

**IMPORTANT:** This phase EXTENDS the existing profile schema. All existing fields (`username`, `password`, `hostname`, `packages`, etc.) remain unchanged and continue to work with `pim serve`.

### 5.1 Update Profile Schema

**Modify:** `home/.config/pim/profiles.d/default.yml`

**Extend, don't replace.** Add new sections alongside existing preseed fields:

```yaml
default:
  # Existing preseed settings (unchanged)
  username: ansible
  password: changeme
  fullname: Ansible User
  locale: en_US.UTF-8
  keyboard: us
  hostname: pim-image
  domain: local
  mirror_host: deb.debian.org
  mirror_path: /debian
  http_proxy: ""
  timezone: UTC
  partitioning_method: regular
  partitioning_recipe: atomic
  tasksel: "standard, ssh-server"
  packages: openssh-server curl sudo
  grub_device: default

  # NEW: Build settings
  build:
    disk_size: 20G
    memory: 2048
    cpus: 2
  
  # NEW: Provisioning scripts
  scripts:
    - base
    # Profile-specific scripts go here
    - finalize
  
  # NEW: Supported architectures
  # If not specified, all architectures with available ISOs are supported
  architectures:
    - arm64
    - x86_64
  
  # NEW: ISO selection pattern
  # Used to find matching ISO in catalog
  # Variables: {arch}, {distro}, {version}
  iso_pattern: "debian-*-{arch}-netinst"
```

**Tasks:**
- [ ] Update PimProfile::Config to handle new schema
- [ ] Add `scripts` field to profile resolution
- [ ] Add `architectures` field to profile resolution
- [ ] Add `build` settings to profile (disk_size, memory, cpus)
- [ ] Implement ISO pattern matching for architecture

### 5.2 ISO Resolution

**Modify:** `home/.local/lib/ruby/pim/iso.rb`

Add method to find ISO by architecture:

```ruby
module PimIso
  class Manager
    # Existing methods...
    
    def find_by_arch(arch, pattern: nil)
      # Find ISO matching architecture and optional pattern
      # Returns best match (most recent version)
    end
    
    def find_by_pattern(pattern, arch:)
      # Pattern like "debian-*-{arch}-netinst"
      # Returns matching ISO or nil
    end
  end
end
```

**Tasks:**
- [ ] Add `find_by_arch` method to ISO manager
- [ ] Add pattern matching with variable substitution
- [ ] Return most recent version when multiple matches

---

## Phase 6: CLI Integration

### 6.1 Build CLI

**Modify:** `home/.local/bin/pim`

Add `build` subcommand:

```ruby
desc 'build SUBCOMMAND', 'Build VM images'
subcommand 'build', PimBuild::CLI
```

**File:** Add CLI class to `home/.local/lib/ruby/pim/build.rb`

```ruby
module PimBuild
  class CLI < Thor
    def self.exit_on_failure? = true
    
    desc 'run PROFILE', 'Build image for profile'
    option :arch, type: :string, aliases: '-a', desc: 'Target architecture (arm64, x86_64)'
    option :force, type: :boolean, aliases: '-f', desc: 'Force rebuild (ignore cache)'
    option :local, type: :boolean, desc: 'Force local build (no remote)'
    option :verbose, type: :boolean, aliases: '-v', desc: 'Verbose output'
    option :dry_run, type: :boolean, aliases: '-n', desc: 'Show what would be done'
    def run(profile_name)
      manager = Manager.new
      manager.build(
        profile_name,
        arch: options[:arch],
        force: options[:force],
        local_only: options[:local],
        verbose: options[:verbose],
        dry_run: options[:dry_run]
      )
    end
    
    desc 'list', 'List built images'
    option :all, type: :boolean, aliases: '-a', desc: 'Include deployed images'
    def list
      manager = Manager.new
      manager.list_images(include_deployments: options[:all])
    end
    
    desc 'show PROFILE', 'Show image details'
    option :arch, type: :string, aliases: '-a', desc: 'Specific architecture'
    def show(profile_name)
      manager = Manager.new
      manager.show_image(profile_name, arch: options[:arch])
    end
    
    desc 'clean', 'Clean build cache'
    option :profile, type: :string, aliases: '-p', desc: 'Clean specific profile'
    option :arch, type: :string, aliases: '-a', desc: 'Clean specific architecture'
    option :all, type: :boolean, desc: 'Clean entire cache'
    def clean
      manager = Manager.new
      if options[:all]
        manager.clean_cache
      else
        manager.clean_cache(profile: options[:profile], arch: options[:arch])
      end
    end
    
    desc 'status', 'Show build system status'
    def status
      # Show: host arch, available builders, remote status
    end
  end
end
```

**Tasks:**
- [ ] Create `PimBuild::CLI` Thor subcommand
- [ ] Implement `build run` command
- [ ] Implement `build list` command
- [ ] Implement `build show` command
- [ ] Implement `build clean` command
- [ ] Implement `build status` command
- [ ] Add to main `pim` CLI as subcommand

---

## Phase 7: Deploy Implementation

### 7.1 Deploy Module

**File:** `home/.local/lib/ruby/pim/deploy.rb`

```ruby
module PimDeploy
  class Config        # Target configuration loader
  class Manager       # Deploy orchestration
  class CLI < Thor    # CLI interface
  
  # Target-specific deployers
  module Targets
    class Base
      def deploy(image_path, config)
      def status
      def remove
    end
    
    class Proxmox < Base
      # Upload qcow2, create template via qm commands
    end
    
    class AWS < Base
      # Convert to raw, upload to S3, import-snapshot, register-image
    end
    
    class UTM < Base
      # Create .utm bundle with qcow2
    end
  end
end
```

**Tasks:**
- [ ] Create base deployer interface
- [ ] Implement Proxmox deployer (SSH + qm commands)
- [ ] Implement AWS deployer (qemu-img + aws cli)
- [ ] Implement UTM deployer (bundle creation)
- [ ] Create deploy manager orchestration
- [ ] Integrate with Registry for deployment tracking
- [ ] Create CLI subcommand

### 7.2 Deploy CLI

```ruby
module PimDeploy
  class CLI < Thor
    desc 'run PROFILE TARGET', 'Deploy image to target'
    option :arch, type: :string, aliases: '-a', desc: 'Source architecture'
    option :force, type: :boolean, aliases: '-f', desc: 'Force redeploy'
    def run(profile_name, target_name)
      # Deploy image to target
    end
    
    desc 'list', 'List deployments'
    def list
      # Show all deployments from registry
    end
    
    desc 'status TARGET', 'Show deployment status'
    def status(target_name)
      # Check target for deployed images
    end
    
    desc 'remove PROFILE TARGET', 'Remove deployment'
    def remove(profile_name, target_name)
      # Remove deployed image from target
    end
  end
end
```

**Tasks:**
- [ ] Implement `deploy run` command
- [ ] Implement `deploy list` command  
- [ ] Implement `deploy status` command
- [ ] Implement `deploy remove` command
- [ ] Add to main `pim` CLI as subcommand

---

## Phase 8: Cleanup and Migration

### 8.1 Remove Packer Dependencies

**Tasks:**
- [ ] Remove `home/.config/pim/templates/packer/` directory
- [ ] Remove `home/.local/lib/ruby/pim/packer.rb`
- [ ] Update `home/.local/bin/pim` to remove packer subcommand
- [ ] Remove `builds.d/` directory (replaced by profile + arch)
- [ ] Update README.md with new architecture

### 8.2 Update Configuration

**Tasks:**
- [ ] Update `pim.yml` with new `build` section
- [ ] Migrate any existing `targets.d/` to new format
- [ ] Create example profiles for common use cases
- [ ] Update default profile with new fields

### 8.3 Documentation

**Tasks:**
- [ ] Update README.md with new commands and workflow
- [ ] Document profile schema
- [ ] Document target configuration
- [ ] Document script development
- [ ] Add troubleshooting guide

---

## Phase 9: Testing

### 9.1 Unit Tests

**Directory:** `home/.local/lib/ruby/pim/test/`

**Tasks:**
- [ ] Test ArchitectureResolver
- [ ] Test CacheManager  
- [ ] Test Registry
- [ ] Test QEMU CommandBuilder
- [ ] Test ScriptLoader
- [ ] Test SSH module (mock)

### 9.2 Integration Tests

**Tasks:**
- [ ] Test full local build (ARM64 on Mac)
- [ ] Test cache hit scenario
- [ ] Test preseed server integration
- [ ] Test SSH provisioning
- [ ] Test image finalization

### 9.3 End-to-End Tests

**Tasks:**
- [ ] Build → Deploy → Verify on Proxmox
- [ ] Build → Deploy → Verify on UTM
- [ ] Build → Deploy → Verify on AWS (if applicable)
- [ ] Remote build test (if remote builder available)

---

## Implementation Order

Recommended order for implementation:

1. **Phase 1.1-1.2**: Core config and registry (foundation)
2. **Phase 4.1**: Create scripts (needed for testing)
3. **Phase 1.3**: SSH module (needed for builds)
4. **Phase 2.1**: QEMU module (core build capability)
5. **Phase 2.2**: Preseed server integration
6. **Phase 3.1**: Local builder (first working build)
7. **Phase 6.1**: Build CLI (usable from command line)
8. **Phase 5.1-5.2**: Profile and ISO updates
9. **Phase 3.2**: Remote builder (cross-arch support)
10. **Phase 7**: Deploy implementation
11. **Phase 8**: Cleanup and migration
12. **Phase 9**: Testing

---

## Success Criteria

### Minimum Viable Product (MVP)

- [ ] `pim build run developer` builds ARM64 image on Mac locally
- [ ] Image includes cloud-init, properly cleaned for templating
- [ ] Build uses cache when profile unchanged
- [ ] Build output shows progress through each phase

### Full Implementation

- [ ] All phases complete
- [ ] Local and remote builds working
- [ ] All three deploy targets working (Proxmox, AWS, UTM)
- [ ] Registry tracks images and deployments
- [ ] Documentation complete
- [ ] Tests passing

---

## Notes for Implementation

### QEMU on macOS

- Use Homebrew: `brew install qemu`
- HVF acceleration requires entitlements for some scenarios
- User-mode networking is simplest for port forwarding
- Serial console output helps debug boot issues

### SSH Provisioning Tips

- Wait for SSH with exponential backoff
- Use `StrictHostKeyChecking=no` for build VMs
- Clean up known_hosts entries after build
- Stream command output for visibility

### Preseed Gotchas

- Preseed URL must be accessible from VM (not localhost)
- Some settings require specific timing in boot_command
- Late commands run in chroot context
- Use `in-target` for commands that need installed system

### Cloud-init Considerations

- NoCloud datasource works for Proxmox and UTM
- AWS uses IMDS automatically
- Clean cloud-init state before templating
- Test first-boot behavior after deployment
