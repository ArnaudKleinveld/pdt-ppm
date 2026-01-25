# pim - Product Image Manager

A Ruby CLI tool for managing product images (ISOs), serving preseed configurations, and building VM/container images via Packer and Docker.

## Features

- **Profile-based configuration**: Define reusable installation profiles with deep-merging support
- **ISO management**: Download, verify, and catalog installation ISOs via `pim iso`
- **Preseed server**: Serve preseed.cfg and post-install scripts via WEBrick
- **Image building**: Build qcow2, Proxmox templates, AWS AMIs, UTM packages, and Docker images
- **Flexible config**: Global, project, and runtime configuration with automatic merging
- **Build caching**: Cached qcow2 images are reused across targets

## Commands

### pim

```bash
pim serve [PROFILE]           # Start preseed server
pim config                    # Show configuration
pim iso SUBCOMMAND            # ISO management
pim profile SUBCOMMAND        # Profile management
pim ventoy SUBCOMMAND         # Ventoy USB management
pim packer SUBCOMMAND         # Image building
```

### pim packer

```bash
pim packer list               # List available builds
pim packer list --targets     # List available targets
pim packer show BUILD         # Show resolved configuration
pim packer build BUILD        # Build a specific image
pim packer build 'debian*'    # Build all matching pattern
pim packer build --all        # Build all defined builds
pim packer build BUILD -n     # Dry run (show what would happen)
pim packer add                # Add new build interactively
pim packer cache              # Show cache status
pim packer cache --clear-all  # Clear entire cache
```

### pim iso

```bash
pim iso list [-l]             # List ISOs (long format shows status)
pim iso download ISO_KEY      # Download a specific ISO
pim iso download --all        # Download all missing ISOs
pim iso verify ISO_KEY        # Verify checksum
pim iso add                   # Add new ISO interactively
```

### pim profile

```bash
pim profile list [-l]         # List profiles
pim profile show NAME         # Show profile details
pim profile add               # Add new profile interactively
```

## Configuration Structure

```
~/.config/pim/
├── pim.yml                   # Runtime config
├── isos.d/                   # ISO catalog
│   └── *.yml
├── profiles.d/               # Installation profiles
│   └── *.yml
├── targets.d/                # Build targets (qcow2, proxmox, aws, etc.)
│   └── *.yml
├── builds.d/                 # Build definitions (iso + profile + target)
│   └── *.yml
├── preseeds.d/               # Preseed templates (ERB)
│   └── *.cfg.erb
├── installs.d/               # Post-install scripts
│   └── *.sh
└── templates/                # Packer/Docker templates
    ├── packer/
    │   ├── qemu.pkr.hcl
    │   └── qemu.pkrvars.hcl.erb
    └── docker/
        └── Dockerfile.erb
```

## Build Definitions

Each build combines an ISO, profile, and target:

```yaml
# builds.d/debian-13-developer-proxmox.yml
debian-13-developer-proxmox:
  iso: debian-13.3.0-amd64-netinst
  profile: developer
  target: proxmox-clone
  overrides:
    disk_size: 50G
    proxmox_vmid: 9002
```

## Available Targets

| Target | Description |
|--------|-------------|
| `qcow2` | Local qcow2 image (base for other targets) |
| `proxmox-iso` | Direct build on Proxmox via packer |
| `proxmox-clone` | Upload qcow2 to Proxmox as template |
| `aws` | Convert qcow2 to AMI |
| `utm` | Package qcow2 for UTM (macOS) |
| `docker` | Build container image (separate path, no ISO) |

## Build Caching

qcow2 images are cached based on a hash of (ISO + profile + preseed + install script). Multiple builds sharing the same iso+profile reuse the cached qcow2:

```bash
# First build creates qcow2
pim packer build debian-13-minimal-qcow2

# These reuse the cached qcow2, only run conversion
pim packer build debian-13-minimal-proxmox
pim packer build debian-13-minimal-aws
```

Cache location: `~/.cache/pim/builds/`

## Examples

```bash
# Build local qcow2 image
pim packer build debian-13-minimal-qcow2

# Build all proxmox targets
pim packer build '*proxmox*'

# Dry run to see what would happen
pim packer build debian-13-minimal-qcow2 --dry-run

# Force rebuild (ignore cache)
pim packer build debian-13-minimal-qcow2 --no-cache

# Build everything
pim packer build --all
```

## Templates

Templates use ERB. Search order:

1. `$PWD/{preseeds.d,installs.d,templates}/...`
2. `$XDG_CONFIG_HOME/pim/{preseeds.d,installs.d,templates}/...`

Variables available in templates are the merged result of:
- ISO data (url, checksum, filename, etc.)
- Profile data (username, packages, timezone, etc.)
- Target data (disk_size, memory, etc.)
- Build overrides

## Dependencies

- Ruby 3.x
- Thor gem
- Packer (for qcow2/proxmox-iso builds)
- QEMU (for local qcow2 builds)
- Docker (for container builds)
- AWS CLI (for AMI imports)
