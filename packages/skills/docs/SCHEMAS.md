# Skills Data Schemas

## Overview

Skills uses three YAML files for data persistence:
- `registry.yml` - Shared skill catalog (version controlled)
- `state.yml` - Local installation state
- `search.yml` - Cached search results

---

## registry.yml

Location: `$XDG_DATA_HOME/skills/registry.yml` (symlinked from pdt-ppm package)

The shared, version-controlled catalog of validated skills.

```yaml
# registry.yml
---
skills:
  solana-spl-a3f2b1c9:
    id: solana-spl-a3f2b1c9
    name: Solana SPL Token Development
    description: MCP server for Solana SPL token operations
    url: https://github.com/anthropics/claude-mcp-servers/tree/main/solana
    tags:
      - blockchain
      - solana
      - rust
      - mcp
    install_type: mcp
    install_cmd: "npx -y @anthropics/claude-code mcp add @anthropics/solana-mcp"
    added_at: 2025-01-28T10:30:00Z
    added_by: roberto

  rails-patterns-7b2e4d1f:
    id: rails-patterns-7b2e4d1f
    name: Rails Development Patterns
    description: Rails 8+ conventions, Hotwire, Solid Queue patterns
    url: https://github.com/pdt/claude-skills/tree/main/rails
    tags:
      - rails
      - ruby
      - web
    install_type: skill_folder
    install_cmd: null
    source: https://github.com/pdt/claude-skills.git
    source_path: rails
    added_at: 2025-01-27T14:00:00Z
    added_by: roberto
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique identifier (generated from URL) |
| `name` | string | yes | Human-readable name |
| `description` | string | yes | One-line description |
| `url` | string | yes | Source URL (used for ID generation) |
| `tags` | array | no | Searchable tags |
| `install_type` | enum | yes | One of: `mcp`, `skill_folder`, `script` |
| `install_cmd` | string | depends | Command to run for `mcp` or `script` types |
| `source` | string | depends | Git URL for `skill_folder` type |
| `source_path` | string | no | Subdirectory within git repo |
| `added_at` | datetime | yes | ISO 8601 timestamp |
| `added_by` | string | no | Who added this skill |

---

## state.yml

Location: `$XDG_DATA_HOME/skills/state.yml` (local only, not symlinked)

Tracks what's installed on this specific machine.

```yaml
# state.yml
---
installed:
  solana-spl-a3f2b1c9:
    id: solana-spl-a3f2b1c9
    installed_at: 2025-01-28T11:00:00Z
    source: registry  # or 'cache'
    version: null     # future: for versioned skills

  rails-patterns-7b2e4d1f:
    id: rails-patterns-7b2e4d1f
    installed_at: 2025-01-27T15:30:00Z
    source: cache
    install_path: ~/.claude/skills/rails-patterns-7b2e4d1f
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Skill identifier |
| `installed_at` | datetime | yes | When installed |
| `source` | enum | yes | Where installed from: `registry` or `cache` |
| `version` | string | no | Version if applicable |
| `install_path` | string | no | Local path for `skill_folder` types |

---

## search.yml

Location: `$XDG_CACHE_HOME/skills/search.yml` (ephemeral, personal)

Stores results from the most recent `skills find` command.

```yaml
# search.yml
---
query: "solana token economics SPL"
searched_at: 2025-01-28T10:30:00Z
provider: claude_code
results:
  solana-spl-a3f2b1c9:
    id: solana-spl-a3f2b1c9
    name: Solana SPL Token Development
    description: MCP server for Solana SPL token operations including minting and transfers
    url: https://github.com/anthropics/claude-mcp-servers/tree/main/solana
    tags:
      - blockchain
      - solana
      - mcp
    install_type: mcp
    install_cmd: "npx -y @anthropics/claude-code mcp add @anthropics/solana-mcp"
    confidence: 0.92

  tokenomics-patterns-c9a1f3e2:
    id: tokenomics-patterns-c9a1f3e2
    name: Token Economics Modeling
    description: Design patterns for tokenomics, vesting schedules, liquidity pools
    url: https://github.com/web3/tokenomics-skill
    tags:
      - blockchain
      - economics
      - modeling
    install_type: skill_folder
    source: https://github.com/web3/tokenomics-skill.git
    confidence: 0.78
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `query` | string | yes | Original search query |
| `searched_at` | datetime | yes | When search was performed |
| `provider` | enum | yes | Which provider: `claude_code` or `api` |
| `results` | map | yes | Skills keyed by ID |

#### Result Entry Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Generated from URL |
| `name` | string | yes | Human-readable name |
| `description` | string | yes | One-line description |
| `url` | string | yes | Source URL |
| `tags` | array | no | Suggested tags |
| `install_type` | enum | yes | One of: `mcp`, `skill_folder`, `script` |
| `install_cmd` | string | depends | For `mcp` and `script` types |
| `source` | string | depends | Git URL for `skill_folder` type |
| `confidence` | float | no | Claude's confidence score (0-1) |

---

## config.yml

Location: `$XDG_CONFIG_HOME/skills/config.yml`

User configuration for the skills CLI.

```yaml
# config.yml
---
search:
  provider: claude_code    # claude_code | api
  max_results: 10
  model: claude-sonnet-4-20250514  # only for api provider

api:
  key_env: ANTHROPIC_API_KEY  # env var name (not the key itself!)

ui:
  interactive: true        # false disables TUI, uses plain output
  colors: true             # false disables color output

paths:                     # override XDG defaults (rarely needed)
  registry: null
  state: null
  cache: null
```

---

## ID Generation Algorithm

IDs are deterministically generated from URLs:

```ruby
require 'digest'

def generate_id(url)
  # 1. Normalize URL
  normalized = url.to_s.downcase.gsub(/\/$/, '')
  
  # 2. Generate hash
  hash = Digest::SHA256.hexdigest(normalized)[0..7]
  
  # 3. Extract human-readable slug
  slug = normalized
    .gsub(%r{https?://}, '')
    .gsub(/github\.com\//, '')
    .gsub(%r{/tree/[^/]+/}, '-')
    .split('/')
    .reject(&:empty?)
    .last(2)
    .join('-')
    .gsub(/[^a-z0-9-]/, '')
    .slice(0, 30)
  
  # 4. Combine
  "#{slug}-#{hash}"
end
```

### Examples

| URL | Generated ID |
|-----|--------------|
| `https://github.com/anthropics/claude-mcp-servers/tree/main/solana` | `solana-a3f2b1c9` |
| `https://github.com/pdt/claude-skills/tree/main/rails` | `rails-7b2e4d1f` |
| `https://www.npmjs.com/package/@anthropic-ai/mcp` | `anthropic-ai-mcp-d4e5f6a7` |

---

## Install Types

### mcp

MCP servers installed via npm/npx or Claude CLI.

```yaml
install_type: mcp
install_cmd: "npx -y @anthropics/claude-code mcp add @anthropics/solana-mcp"
```

### skill_folder

Git repos cloned to `~/.claude/skills/{id}/`

```yaml
install_type: skill_folder
source: https://github.com/pdt/claude-skills.git
source_path: rails  # optional subdirectory
```

Installation creates:
```
~/.claude/skills/rails-patterns-7b2e4d1f/
├── SKILL.md
├── prompts/
└── examples/
```

### script

Custom installation via shell command.

```yaml
install_type: script
install_cmd: "curl -sL https://example.com/install.sh | bash"
```

Use sparingly - prefer `mcp` or `skill_folder` when possible.
