# Skills

AI Development Skills Manager - discover, install, and share Claude skills, MCP servers, and tool configurations.

## Quick Start

```bash
# Install the package
ppm install skills

# Search for skills
skills find "solana token development"

# Install from search results
skills install solana-spl-a3f2b1c9

# Share with team (adds to registry)
skills add solana-spl-a3f2b1c9
```

## How It Works

### The Promotion Pipeline

```
Discovery → Cache → Install (personal) → Add (share) → Install (team)
```

1. **find**: Search the web via Claude, results cached locally
2. **install**: Try a skill from cache
3. **add**: Promote validated skill to shared registry
4. **install**: Team members install from registry

### Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `skills find <query>` | `sf` | Search for skills via Claude |
| `skills list [pattern]` | `sl` | List registry and cache |
| `skills show <id>` | `ss` | Show skill details |
| `skills install <id>` | `si` | Install a skill |
| `skills uninstall <id>` | - | Remove installed skill |
| `skills add <id>` | `sa` | Add cache entry to registry |
| `skills remove <id>` | `sr` | Remove from registry |
| `skills state` | `sst` | Show installed skills |

### File Locations

```
~/.config/skills/config.yml     # Configuration
~/.local/share/skills/
├── registry.yml                # Shared catalog (symlinked)
└── state.yml                   # Local installs
~/.cache/skills/search.yml      # Search results
```

## Configuration

Edit `~/.config/skills/config.yml`:

```yaml
search:
  provider: claude_code    # or 'api' for direct API
  max_results: 10

ui:
  interactive: true        # TUI menus
  colors: true
```

## For Developers

See `CLAUDE.md` for architecture and implementation details.
