# ADR-001: PIM Build Architecture - Direct QEMU Image Building

## Status

**Accepted and Implemented** (February 2026)

## Date

2025-01-27 (proposed), 2026-02-09 (implemented)

## Context

PIM originally used Packer as the image building engine, wrapping Packer HCL templates with Ruby orchestration. This added complexity without providing significant value since PIM exclusively builds qcow2 as a universal intermediate format and already has its own preseed server.

## Decision

Remove Packer entirely. PIM directly orchestrates QEMU for image building.

### Architecture

```
ISO → PIM (Ruby + QEMU) → qcow2 → PIM Deploy → Targets
```

### Core Principles

1. **qcow2 as Universal Intermediate**: All builds produce qcow2 images with cloud-init installed
2. **Direct QEMU orchestration**: No Packer, no HCL templates
3. **SSH + shell scripts for provisioning**: No Ansible at build time
4. **Smart Architecture Routing**: Builds route to local or remote builder based on host/target architecture
5. **Cloud-init for deploy-time config**: Images are generic; identity applied at deployment
6. **QMP + Guest Agent for VM management**: Full programmatic control of running VMs

### Smart Architecture Routing

| Host | Target | Builder |
|------|--------|---------|
| Mac M-series | arm64 | Local (HVF) |
| Mac M-series | x86_64 | Remote (Proxmox KVM) |
| Linux x86_64 | x86_64 | Local (KVM) |
| Linux x86_64 | arm64 | Remote (if available) |

### Runtime Conventions

- Sockets in `$XDG_RUNTIME_DIR/pim/` (or `/tmp/pim/`)
- Named: `<image>.qmp`, `<image>.ga`, `<image>.serial`, `<image>.pid`
- Guest agent via virtio-serial channel `org.qemu.guest_agent.0`
- QMP for host-side VM control (status, shutdown)
- Headless by default using `nohup` (not `-daemonize` due to macOS vmnet fork crash)

### Pipeline

| Component | Responsibility |
|-----------|---------------|
| `pim build` | Create qcow2 images from ISO via QEMU |
| `pim deploy` | Upload/convert images to targets (Proxmox, AWS) |
| `tofu` | Provision infrastructure using deployed images |
| `ansible` | Day-2 operations |

## Consequences

### Positive
- Simplified stack — all build logic in Ruby
- Faster iteration — direct QEMU control
- Better caching — PIM controls cache logic
- Clear separation of build/deploy/provision/maintain

### Negative
- More code in PIM (responsibility Packer handled)
- QEMU expertise required
- Root required for vmnet-bridged networking on macOS

## Alternatives Rejected

- **Keep Packer, remove Ansible**: Still adds HCL complexity for no benefit
- **virt-builder/virt-customize**: Less flexible, less portable
- **cloud-init only (no SSH provisioning)**: runcmd too limited, SSH allows interactive debugging
