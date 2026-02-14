# CLAUDE.md - PPM Ecosystem Guide

This file documents the PPM (Personal Package Manager) ecosystem for Claude Code reference.

## Overview

The PPM ecosystem consists of three repositories that work together:

| Repo | Purpose | URL |
|------|---------|-----|
| **ppm** | Core package manager tool | https://github.com/maxcole/ppm |
| **pde-ppm** | Personal Development Environment packages | https://github.com/maxcole/pde-ppm |
| **pdt-ppm** | Product Development Toolkit packages | https://github.com/maxcole/pdt-ppm |

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                         ppm (tool)                          │
│  - Manages sources.list (repo URLs)                         │
│  - Clones/updates repos to ~/.local/share/ppm/              │
│  - Stows package files to $HOME                             │
│  - Runs install.sh scripts                                  │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│       pde-ppm           │     │       pdt-ppm           │
│  (Dev Environment)      │     │  (Dev Toolkit)          │
│                         │     │                         │
│  Packages:              │     │  Packages:              │
│  - claude               │     │  - claude (overrides)   │
│  - git                  │     │  - solana               │
│  - nvim                 │     │  - node                 │
│  - mise                 │     │  - etc.                 │
│  - zsh                  │     │                         │
│  - tmux                 │     │                         │
│  - etc.                 │     │                         │
└─────────────────────────┘     └─────────────────────────┘
```

## Key Directories

```bash
~/.local/bin/ppm              # The ppm executable
~/.config/ppm/sources.list    # List of repo URLs (priority order)
~/.local/share/ppm/           # Cloned repos
  ├── pde-ppm/packages/       # pde-ppm packages
  └── pdt-ppm/packages/       # pdt-ppm packages
```

## Package Structure

Each package in `packages/` can contain:

```
packages/claude/
├── home/                     # Stowed to $HOME
│   └── .config/
│       ├── mise/conf.d/
│       │   └── claude.toml   # mise tool config
│       └── zsh/
│           └── claude.zsh    # zsh aliases/functions
├── install.sh                # Optional install script
└── space/                    # Optional "space" config
```

### install.sh Functions

```bash
dependencies()    # Return space-separated list of deps
pre_install()     # Run before stowing
post_install()    # Run after stowing
install_macos()   # OS-specific install
install_linux()   # OS-specific install
pre_remove()      # Run before unstowing
post_remove()     # Run after unstowing
```

## Precedence

Repos in `sources.list` are processed in order. **First occurrence wins** - packages in earlier repos override later ones.

Typical order:
1. Personal fork (highest priority, your customizations)
2. pde-ppm (development environment)
3. pdt-ppm (development toolkit)

## Common Commands

```bash
# Update repos (git pull)
ppm update

# Update ppm itself
ppm update ppm

# List packages
ppm list
ppm list claude

# Install packages
ppm install claude
ppm install pde-ppm/claude    # From specific repo
ppm install -f claude         # Force reinstall

# Show package info
ppm show claude

# Package path
ppm path claude
```

## Claude Code Installation

Claude Code is installed via **mise** (version manager).

### How It Works

1. ppm stows `~/.config/mise/conf.d/claude.toml`
2. mise reads this config and installs claude
3. The `post_install()` in `install.sh` runs `mise install claude`

### claude.toml Configuration

```toml
# Use npm backend (recommended - official distribution)
[tools]
"npm:@anthropic-ai/claude-code" = "latest"
```

**Important:** Do NOT use the shorthand `claude = "latest"` as it resolves to the `aqua` backend which may be broken for newer versions.

### Upgrading Claude

```bash
# Option 1: Via mise directly
mise upgrade npm:@anthropic-ai/claude-code

# Option 2: Reinstall via ppm
ppm install -f claude
```

### Troubleshooting

If `mise upgrade claude` fails with "Http backend requires 'url' option":

1. The aqua backend is broken
2. Fix: Edit `claude.toml` to use npm backend explicitly
3. Run `mise install npm:@anthropic-ai/claude-code`

## mise Integration

pde-ppm uses mise for tool version management. Each package can provide a `.toml` config in:

```
home/.config/mise/conf.d/<package>.toml
```

These are stowed to `~/.config/mise/conf.d/` where mise reads them.

### mise Backends

| Backend | Syntax | Notes |
|---------|--------|-------|
| npm | `"npm:@scope/pkg" = "version"` | For npm packages |
| aqua | `tool = "version"` | Uses aqua registry |
| core | `node = "version"` | Built-in support |

## Personal Fork (pdt-ppm-fork)

This fork of pdt-ppm contains personal customizations that override packages from pde-ppm and pdt-ppm.

To use:
1. Add to top of sources.list: `git@github.com:yourusername/pdt-ppm-fork`
2. Run `ppm update`
3. Your customizations take precedence

## Useful Links

- ppm README: https://github.com/maxcole/ppm#readme
- pde-ppm README: https://github.com/maxcole/pde-ppm#readme
- mise docs: https://mise.jdx.dev/
- Claude Code npm: https://www.npmjs.com/package/@anthropic-ai/claude-code
