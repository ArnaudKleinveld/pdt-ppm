# Skills - AI Development Skills Manager

## Project Context

Skills is a Ruby CLI tool for discovering, installing, and managing AI development skills (MCP servers, Claude skills, tool configurations). It provides a team-shareable registry with personal discovery via Claude-powered web search.

## Key Documentation

- **Implementation Plan:** `docs/PROJECT-PLAN.md`
- **Data Schemas:** `docs/SCHEMAS.md`

## Architecture Overview

### The Promotion Pipeline

```
Discovery → Cache → Install (personal) → Add (share) → Install (team)
```

1. **find**: User searches the web via Claude, results cached locally
2. **install --cache**: User installs from cache to try it out
3. **add**: User promotes validated skill to shared registry
4. **install**: Team members install from shared registry

### File Locations

```
$XDG_CONFIG_HOME/skills/
└── config.yml              # behavior settings

$XDG_DATA_HOME/skills/
├── registry.yml → (symlink)  # shared catalog (from pdt-ppm)
└── state.yml               # what's installed locally

$XDG_CACHE_HOME/skills/
└── search.yml              # find results, ephemeral
```

The `registry.yml` is symlinked from the pdt-ppm package, making it version-controlled and team-shared via `ppm update`.

## Code Organization

```
home/.local/bin/skills                 # Main CLI entry point (dry-cli)
home/.local/lib/ruby/skills/
├── config.rb                          # Configuration loader
├── registry.rb                        # Registry CRUD operations
├── cache.rb                           # Search cache management
├── state.rb                           # Local installation state
├── search.rb                          # Claude invocation (provider-agnostic)
├── search/
│   ├── claude_code.rb                 # Claude Code CLI provider
│   └── api.rb                         # Anthropic API provider
├── installer.rb                       # Install dispatcher by type
├── installer/
│   ├── mcp.rb                         # MCP server installer
│   ├── skill_folder.rb                # Git clone to ~/.claude/skills
│   └── script.rb                      # Custom script executor
├── id.rb                              # Idempotent ID generation
├── ui.rb                              # TTY prompts and display
└── templates/
    └── search_results.yml.erb         # ERB template for output
```

## CLI Interface

```bash
skills find <query>          # Web search via Claude, writes to cache
skills list [pattern]        # List registry + cache, indicate source
skills show <id>             # Detail view of a skill
skills install <id> [-y]     # Install from registry or cache
skills uninstall <id>        # Remove, update state.yml
skills add <id>              # Promote from cache to registry
skills remove <id>           # Remove from registry
skills state                 # Show what's installed locally
```

## Key Design Decisions

### Idempotent Skill IDs

IDs are generated from the source URL using SHA256, ensuring:
- Same URL always produces same ID
- Cache entries can be matched/updated reliably
- No manual ID assignment needed

```ruby
def skill_id(url)
  normalized = url.downcase.gsub(/\/$/, '')
  hash = Digest::SHA256.hexdigest(normalized)[0..7]
  slug = extract_slug(normalized)
  "#{slug}-#{hash}"
end
```

### Search Provider Abstraction

The `find` command uses a pluggable provider:
- `claude_code`: Uses Claude Code CLI (subscription)
- `api`: Uses Anthropic API (credits)

Configured in `config.yml`:
```yaml
search:
  provider: claude_code  # or 'api'
```

### Install Types

Skills can be installed in different ways:
- `mcp`: Run `npx` or `claude mcp add` command
- `skill_folder`: Clone git repo to `~/.claude/skills/`
- `script`: Execute arbitrary install script

### TUI with TTY Gems

Interactive mode uses TTY gems for:
- Selection menus after `find`
- Confirmation prompts for destructive actions
- Colored, formatted output

## Patterns to Follow

### Configuration Loading

Use XDG directories with defaults:
```ruby
XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
XDG_DATA_HOME = ENV.fetch('XDG_DATA_HOME', File.expand_path('~/.local/share'))
XDG_CACHE_HOME = ENV.fetch('XDG_CACHE_HOME', File.expand_path('~/.cache'))
```

### CLI Structure (dry-cli)

```ruby
require 'dry/cli'

module Skills
  module CLI
    module Commands
      extend Dry::CLI::Registry

      class Find < Dry::CLI::Command
        desc "Search for skills"

        argument :query, required: true, desc: "Search query"
        option :max, type: :integer, default: 10, desc: "Maximum results"

        def call(query:, **options)
          # ...
        end
      end

      register "find", Find
    end
  end
end

Dry::CLI.new(Skills::CLI::Commands).call
```

### YAML File Operations

Always handle missing files gracefully:
```ruby
def load_yaml(path)
  return {} unless File.exist?(path)
  YAML.load_file(path) || {}
rescue Psych::SyntaxError => e
  warn "Warning: Failed to parse #{path}: #{e.message}"
  {}
end
```

## Dependencies

Ruby gems:
- `dry-cli` - CLI framework
- `tty-prompt` - Interactive prompts
- `tty-table` - Formatted tables
- `pastel` - Terminal colors

System tools:
- `claude` - Claude Code CLI (for search)
- `npx` - For MCP server installation
- `git` - For skill folder cloning

## Testing

```bash
# Search for skills
skills find "solana token development"

# List what's in cache
skills list --cache

# Install from cache
skills install solana-spl-a3f2b1c9 -y

# Promote to registry
skills add solana-spl-a3f2b1c9

# Check installation state
skills state
```

## Important Notes

1. **Registry is shared** - Changes to registry.yml affect all team members after `ppm update`
2. **Cache is personal** - Each user's search results are local only
3. **State is personal** - What's installed varies per machine
4. **IDs are deterministic** - Same URL = same ID, always
