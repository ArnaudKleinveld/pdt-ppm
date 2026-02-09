# pim - Product Image Manager

A Ruby CLI tool for building, managing, and deploying VM images using QEMU.

## Features

- **ISO management**: Download, verify, and catalog installation ISOs
- **Profile-based configuration**: Deep-merging installation profiles
- **Preseed server**: Serve preseed.cfg and post-install scripts via WEBrick
- **QEMU image building**: Build qcow2 images directly (no Packer)
- **VM lifecycle management**: Run, monitor, and stop VMs with QMP and guest agent
- **Build caching**: Content-based caching of built images

## Commands

```bash
pim serve [PROFILE]           # Start preseed server
pim config                    # Show configuration
pim iso list|download|verify  # ISO management
pim profile list|show         # Profile management
pim build run PROFILE         # Build qcow2 image
pim ventoy SUBCOMMAND         # Ventoy USB management
```

## VM Lifecycle (ZSH helpers)

```bash
pim-run [name] [--bridged] [--console]  # Boot image (headless by default)
pim-ps                                   # List running VMs
pim-stop <name>                          # Graceful shutdown
pim-console <name>                       # Attach serial console (Ctrl-] to detach)
pim-status <name>                        # VM status via QMP
pim-ip <name>                            # Guest network interfaces
pim-os <name>                            # Guest OS info
```

## Configuration

```
~/.config/pim/
├── pim.yml              # Runtime config
├── isos.d/              # ISO catalog
├── profiles.d/          # Installation profiles
├── preseeds.d/          # Preseed templates (ERB)
├── installs.d/          # Late-command scripts
└── scripts.d/           # SSH provisioning scripts
```

## Architecture

```
ISO → PIM (Ruby + QEMU) → qcow2 → Deploy → Targets
```

PIM directly orchestrates QEMU for image building. No Packer, no Ansible at build time. SSH + shell scripts handle post-install provisioning. Images include cloud-init and qemu-guest-agent for deploy-time configuration.

## Dependencies

- Ruby 3.x with gems: thor, net-ssh, net-scp
- QEMU (`brew install qemu` on macOS)
- socat (`brew install socat` on macOS) for VM management
