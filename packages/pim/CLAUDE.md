# PIM - Product Image Manager

## What PIM Does

PIM is a Ruby CLI tool that builds VM images from ISOs using QEMU directly. It manages the full lifecycle: ISO catalog → preseed/autoinstall → QEMU build → qcow2 output → deployment to targets.

## Architecture

```
ISO → PIM (Ruby + QEMU) → qcow2 → PIM Deploy → Targets
```

No Packer. No Ansible at build time. QEMU is invoked directly by PIM's Ruby code. SSH + shell scripts handle post-install provisioning.

## Current Working State

### Working Commands
- `pim iso list|download|verify|config` - ISO catalog management
- `pim profile list|show` - Profile management
- `pim serve [PROFILE]` - WEBrick preseed/autoinstall server
- `pim build run PROFILE` - Build qcow2 image via QEMU
- `pim ventoy` - Ventoy USB management

### Working ZSH Functions (macOS only)
Shell helpers in `home/.config/zsh/pim.zsh` for VM lifecycle:
- `pim-run [name] [--bridged] [--console]` - Boot a qcow2 image
- `pim-ps` - List running PIM VMs
- `pim-stop <name>` - Graceful shutdown (guest agent → QMP fallback)
- `pim-console <name>` - Attach serial console (Ctrl-] to detach)
- `pim-status <name>` - VM status via QMP
- `pim-ip <name>` - Guest network interfaces via guest agent
- `pim-os <name>` - Guest OS info via guest agent
- `pim-qmp <name> <json>` - Raw QMP command
- `pim-ga <name> <json>` - Raw guest agent command

## QEMU Runtime Conventions

### Sockets and State
All runtime state lives in `$XDG_RUNTIME_DIR/pim/` (falls back to `/tmp/pim/` on macOS):
- `<name>.qmp` - QMP control socket
- `<name>.ga` - Guest agent socket (virtio-serial)
- `<name>.serial` - Serial console socket (headless mode only)
- `<name>.pid` - QEMU process PID
- `<name>.log` - QEMU stdout/stderr

### Important: Root Ownership
When using `--bridged` (vmnet-bridged), QEMU runs as root via sudo. All sockets, pidfiles, and the QEMU process are root-owned. All queries (QMP, guest agent, pid checks) require `sudo`.

### Guest Agent
Images include `qemu-guest-agent`. The host connects via a virtio-serial channel named `org.qemu.guest_agent.0`. The agent needs ~1 second to respond — socat queries must include a sleep:
```bash
(echo '{"execute":"guest-info"}'; sleep 1) | sudo socat - UNIX-CONNECT:/tmp/pim/<name>.ga
```

### Headless vs Console Mode
- Default: headless with `-display none`, serial on a socket, `nohup` backgrounded
- `--console`: `-nographic`, foreground, serial on terminal
- macOS caveat: cannot use QEMU's `-daemonize` flag with vmnet-bridged due to ObjC runtime fork() crash

### Networking
- `--bridged`: vmnet-bridged on en0, VM gets LAN IP (requires sudo)
- Default: user-mode with `hostfwd=tcp::2222-:22`

## Code Organization

```
home/.local/bin/pim                    # Main CLI (Thor)
home/.local/lib/ruby/pim/
├── iso.rb                             # PimIso - ISO catalog management
├── profile.rb                         # PimProfile - profile loading with deep merge
├── config.rb                          # Pim::Config - XDG config loading
├── build.rb                           # PimBuild - build orchestration
├── build/
│   ├── local_builder.rb               # Local QEMU build
│   └── manager.rb                     # Build manager
├── qemu.rb                            # QEMU wrapper
├── ssh.rb                             # SSH/SCP wrapper
├── registry.rb                        # Image registry
└── ventoy.rb                          # Ventoy USB management
```

## Configuration (XDG)

```
~/.config/pim/
├── pim.yml              # Runtime config
├── isos.d/              # ISO catalog YAML files
├── profiles.d/          # Installation profiles (deep merge from default)
├── preseeds.d/          # Preseed templates (ERB)
├── installs.d/          # Late-command scripts (run during preseed)
└── scripts.d/           # SSH provisioning scripts (run post-install)

~/.local/share/pim/
├── images/              # Built qcow2 images + EFI vars
└── registry.yml         # Image tracking

~/.cache/pim/
└── isos/                # Downloaded ISOs
```

## Key Patterns

### Deep Merge from Default
All config types merge named entries over `default`:
```ruby
profile = DeepMerge.merge(profiles['default'], profiles['developer'])
```

### Template/Script Naming Convention
Files match profile name with fallback to `default`:
- `preseeds.d/developer.cfg.erb` → fallback `preseeds.d/default.cfg.erb`
- `scripts.d/developer.sh` → fallback `scripts.d/default.sh`

### Preseed Server Reuse
`pim build` wraps the existing `Pim::Server` (WEBrick) in a background thread. Do not create a new HTTP server.

## Dependencies

Ruby gems: `thor`, `net-ssh`, `net-scp`
System: `qemu`, `qemu-img`, `socat` (for socket queries)

## Testing

BATS integration tests under `packages/pim/tests/`. Uses the package's own config via XDG_CONFIG_HOME and real cache/data dirs. Requires ISOs to be downloaded. See `packages/pim/tests/pim.bash`.
