# PIM Build System - Implementation Status

_This file replaces the original PROJECT-PLAN-build-system.md which described the Packer-to-QEMU migration plan. That migration is complete._

## What's Done

- [x] Direct QEMU build orchestration (no Packer)
- [x] Local builder for ARM64 on Mac (HVF acceleration)
- [x] ISO catalog management (`pim iso`)
- [x] Profile management with deep merge (`pim profile`)
- [x] Preseed server integration (`pim serve`)
- [x] SSH provisioning with shell scripts
- [x] Cloud-init + qemu-guest-agent in built images
- [x] Image registry tracking
- [x] VM lifecycle management via ZSH helpers (QMP + guest agent)
- [x] BATS test scaffolding for `pim iso`

## What's Next

- [ ] `pim vm` CLI subcommand (port zsh helpers to Ruby)
- [ ] Remote builder for cross-architecture builds
- [ ] Deploy targets: Proxmox, AWS
- [ ] Build caching with content-based keys
- [ ] UTM deploy target (low priority — QEMU direct is sufficient)
