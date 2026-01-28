# PIM - Product Image Manager

## Project Context

PIM is a Ruby CLI tool for building, managing, and deploying VM images. It's being refactored to remove Packer dependency and directly orchestrate QEMU for image building.

## Key Documentation

- **Architecture Decision:** `docs/ADR-001-pim-build-architecture.md`
- **Implementation Plan:** `docs/PROJECT-PLAN-build-system.md`

## Current State

The codebase currently has:
- `pim serve` - Working preseed/autoinstall server
- `pim iso` - ISO catalog management  
- `pim profile` - Profile management
- `pim packer` - **TO BE REPLACED** by new `pim build`

## CRITICAL: Reuse Existing Infrastructure

**DO NOT recreate what already exists.** The new `pim build` system MUST leverage:

### 1. isos.d/ - ISO Catalog (PimIso module)
- Already handles ISO downloading, verification, and catalog management
- Use `PimIso::Manager` and `PimIso::Config` to resolve ISOs by architecture
- Add `find_by_arch(arch)` method if needed, but build on existing code

### 2. profiles.d/ - Installation Profiles (PimProfile module)  
- Already handles profile loading with deep merge from default
- Use `PimProfile::Config` and `PimProfile::Manager` to load profiles
- Extend the schema (add `scripts`, `architectures`, `build` sections) but keep existing fields

### 3. preseeds.d/ - Preseed Templates (Pim::Profile class)
- Already handles ERB template resolution (project then global)
- The `Pim::Profile#preseed_template` method finds templates
- **Reuse this directly** - no changes needed

### 4. installs.d/ - Late-command Scripts (Pim::Profile class)
- Already handles install script resolution
- The `Pim::Profile#install_template` method finds scripts
- **Reuse this directly** - these run during preseed late_command

### 5. Pim::Server - Preseed HTTP Server
- Already serves preseed.cfg and install.sh via WEBrick
- **Wrap this in PimBuild::PreseedServer** to run in background thread
- Don't rewrite the server logic, just orchestrate it

## CRITICAL: Follow Existing Patterns

### Pattern 1: Default Config Deep Merge

All config types use a `default` entry that merges into named entries:

```yaml
# profiles.d/default.yml
default:
  username: ansible
  packages: openssh-server curl sudo

# profiles.d/developer.yml  
developer:
  packages: openssh-server curl sudo git vim  # overrides default
  # username: ansible  <- inherited from default
```

The existing `PimProfile::Config#profile(name)` method already does this:
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

**New code MUST follow this same pattern** for any new config types.

### Pattern 2: Naming Conventions

Templates and scripts follow a naming convention tied to profile name:

| Profile Name | Preseed Template | Install Script |
|--------------|------------------|----------------|
| `default` | `preseeds.d/default.cfg.erb` | `installs.d/default.sh` |
| `developer` | `preseeds.d/developer.cfg.erb` | `installs.d/developer.sh` |
| `k8s-node` | `preseeds.d/k8s-node.cfg.erb` | `installs.d/k8s-node.sh` |

If a profile-specific template doesn't exist, it falls back to `default`:
```ruby
def preseed_template(name = nil)
  name ||= @name
  find_template('preseeds.d', "#{name}.cfg.erb") ||
    (name != 'default' && find_template('preseeds.d', 'default.cfg.erb'))
end
```

**New scripts.d/ MUST follow the same pattern** - profile name match, then fallback to default.

### Pattern 3: MANDATORY - Use Existing Pim::Server

**The `pim build` command MUST use the existing `Pim::Server` class for serving preseed and install scripts.**

The server already:
- Renders `preseeds.d/*.cfg.erb` with profile data via ERB
- Serves `installs.d/*.sh` as-is
- Binds to the correct network interface (not localhost)
- Provides URLs for preseed and install script

The build code should:
```ruby
# CORRECT: Use existing server
server = Pim::Server.new(
  profile: profile,
  port: available_port,
  preseed_name: profile_name,   # Uses profile name convention
  install_name: profile_name    # Uses profile name convention
)

# Start in background thread
thread = Thread.new { server.start }

# Get URLs for QEMU boot command
preseed_url = "http://#{server.ip}:#{server.port}/preseed.cfg"
install_url = "http://#{server.ip}:#{server.port}/install.sh"
```

**DO NOT:**
- Create a new HTTP server
- Reimplement template rendering
- Manually read preseed/install files

### Example: How Build Should Use Existing Code

```ruby
# In PimBuild::Manager#build
def build(profile_name, arch:)
  # Use existing profile loading
  profile_config = PimProfile::Config.new
  profile_data = profile_config.profile(profile_name)
  profile = Pim::Profile.new(profile_name, profile_data)
  
  # Use existing ISO management
  iso_config = PimIso::Config.new
  iso = find_iso_for_arch(iso_config.isos, arch)
  iso_manager = PimIso::Manager.new(config: iso_config)
  iso_manager.download(iso_key) unless iso_downloaded?(iso)
  
  # Use existing preseed/install templates
  preseed_template = profile.preseed_template  # Already works!
  install_script = profile.install_template    # Already works!
  
  # Wrap existing server
  server = Pim::Server.new(profile: profile, port: find_available_port)
  # ... run server in background thread
end
```

## Implementation Goal

Replace `pim packer` with a new `pim build` system that:
1. Directly orchestrates QEMU (no Packer)
2. Uses SSH for post-install provisioning (no Ansible at build time)
3. Produces cloud-init ready qcow2 images
4. Supports smart architecture routing (local vs remote builders)
5. Tracks images in a registry for tofu/ansible consumption

## Directory Structure

```
~/.config/pim/           # Configuration
├── pim.yml              # Runtime config
├── isos.d/              # ISO catalog
├── profiles.d/          # Installation profiles
├── targets.d/           # Deploy targets
├── preseeds.d/          # Preseed templates (ERB)
├── installs.d/          # Late-command scripts
└── scripts.d/           # NEW: SSH provisioning scripts

~/.local/share/pim/      # Data
├── cache/images/        # Built qcow2 images
└── registry.yml         # Image/deployment tracking

~/.cache/pim/            # Cache
└── isos/                # Downloaded ISOs
```

## Code Organization

```
home/.local/bin/pim                    # Main CLI entry point
home/.local/lib/ruby/pim/
├── iso.rb                             # ISO management
├── profile.rb                         # Profile management
├── ventoy.rb                          # Ventoy USB management
├── packer.rb                          # DEPRECATED - to be removed
├── build.rb                           # NEW: Build orchestration
├── build/
│   ├── local_builder.rb               # NEW: Local QEMU builds
│   ├── remote_builder.rb              # NEW: Remote SSH builds
│   ├── manager.rb                     # NEW: Build manager
│   └── script_loader.rb               # NEW: Script discovery
├── deploy.rb                          # NEW: Deploy orchestration
├── deploy/
│   ├── proxmox.rb                     # NEW: Proxmox deployer
│   ├── aws.rb                         # NEW: AWS deployer
│   └── utm.rb                         # NEW: UTM deployer
├── qemu.rb                            # NEW: QEMU wrapper
├── ssh.rb                             # NEW: SSH/SCP wrapper
└── registry.rb                        # NEW: Image registry
```

## Key Patterns

### Configuration Loading
Uses XDG directories with project override:
```ruby
XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
# 1. Load global config
# 2. Deep merge with project config
```

### CLI Structure
Uses Thor gem with subcommands:
```ruby
class CLI < Thor
  def self.exit_on_failure? = true
  desc 'subcommand', 'Description'
  subcommand 'subcommand', SubcommandCLI
end
```

### Deep Merge
All configs use deep merge for layering:
```ruby
module DeepMerge
  def self.merge(base, overlay)
    # Recursively merge hashes
  end
end
```

## Build Flow Summary

```
pim build run developer --arch arm64
│
├── 1. Resolve profile (developer.yml + default.yml)
├── 2. Select builder (local if arch matches host, else remote)
├── 3. Check cache (hash of profile + scripts + iso)
├── 4. Resolve ISO for architecture
├── 5. Create disk image (qemu-img create)
├── 6. Start preseed server (background thread)
├── 7. Start QEMU with ISO boot
├── 8. Wait for SSH (poll port 22)
├── 9. Run provisioning scripts via SSH
├── 10. Finalize (cloud-init clean, truncate machine-id)
├── 11. Shutdown VM
└── 12. Register in image registry
```

## Testing

Test locally on Mac with ARM64:
```bash
# Build ARM64 image (native on M-series Mac)
pim build run developer --arch arm64

# Force rebuild ignoring cache
pim build run developer --arch arm64 --force

# Dry run to see what would happen
pim build run developer --arch arm64 --dry-run
```

## Dependencies

Ruby gems needed:
- thor (CLI framework)
- net-ssh (SSH connections)
- net-scp (file transfer)

System tools needed:
- qemu (image building)
- qemu-img (disk management)
- ssh (fallback for SSH operations)

## Important Notes

1. **Existing code works** - Don't break `pim serve`, `pim iso`, `pim profile`
2. **Incremental implementation** - Follow the phases in PROJECT-PLAN
3. **Test on Mac ARM64 first** - That's the primary dev environment
4. **Keep preseed server** - It's already working and will be reused
5. **Remove packer.rb last** - Only after new build system is working
