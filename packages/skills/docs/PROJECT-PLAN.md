# Skills Implementation Plan

## Project Overview

Implement a CLI tool for discovering, installing, and managing AI development skills with team-shareable registry and personal discovery via Claude-powered web search.

**Reference:** See `CLAUDE.md` for architecture overview and patterns.

## Prerequisites

Before starting implementation:

1. Ruby 3.x installed via mise
2. Gems: `dry-cli`, `tty-prompt`, `tty-table`, `pastel`
3. Claude Code CLI installed (`claude` command available)
4. Understanding of ppm package structure

## Phase 1: Foundation

**Goal:** Basic file structure, configuration loading, and ID generation.

### 1.1 Create Configuration Loader

File: `home/.local/lib/ruby/skills/config.rb`

```ruby
module Skills
  class Config
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    XDG_DATA_HOME = ENV.fetch('XDG_DATA_HOME', File.expand_path('~/.local/share'))
    XDG_CACHE_HOME = ENV.fetch('XDG_CACHE_HOME', File.expand_path('~/.cache'))

    CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'skills')
    DATA_DIR = File.join(XDG_DATA_HOME, 'skills')
    CACHE_DIR = File.join(XDG_CACHE_HOME, 'skills')

    def initialize
      ensure_directories
      @config = load_config
    end

    def search_provider
      @config.dig('search', 'provider') || 'claude_code'
    end

    def search_max_results
      @config.dig('search', 'max_results') || 10
    end

    def interactive?
      @config.dig('ui', 'interactive') != false
    end

    def colors?
      @config.dig('ui', 'colors') != false
    end

    def registry_path
      File.join(DATA_DIR, 'registry.yml')
    end

    def state_path
      File.join(DATA_DIR, 'state.yml')
    end

    def cache_path
      File.join(CACHE_DIR, 'search.yml')
    end

    private

    def ensure_directories
      [CONFIG_DIR, DATA_DIR, CACHE_DIR].each do |dir|
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      end
    end

    def load_config
      config_file = File.join(CONFIG_DIR, 'config.yml')
      return {} unless File.exist?(config_file)
      YAML.load_file(config_file) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse config: #{e.message}"
      {}
    end
  end
end
```

### 1.2 Create ID Generator

File: `home/.local/lib/ruby/skills/id.rb`

```ruby
require 'digest'

module Skills
  module Id
    def self.generate(url)
      normalized = url.to_s.downcase.gsub(/\/$/, '')
      hash = Digest::SHA256.hexdigest(normalized)[0..7]
      slug = extract_slug(normalized)
      "#{slug}-#{hash}"
    end

    def self.extract_slug(url)
      url
        .gsub(%r{https?://}, '')
        .gsub(/github\.com\//, '')
        .gsub(%r{/tree/[^/]+/}, '-')
        .split('/')
        .reject(&:empty?)
        .last(2)
        .join('-')
        .gsub(/[^a-z0-9-]/, '')
        .slice(0, 30)
    end
  end
end
```

### 1.3 Create Stub CLI

File: `home/.local/bin/skills`

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'dry/cli'
require 'yaml'
require 'fileutils'

# Load libraries
require 'skills/config'
require 'skills/id'

module Skills
  module CLI
    module Commands
      extend Dry::CLI::Registry

      class Version < Dry::CLI::Command
        desc "Show version"

        def call(*)
          puts "skills 0.1.0"
        end
      end

      register "version", Version
    end
  end
end

Dry::CLI.new(Skills::CLI::Commands).call
```

### Verification

```bash
skills version
# => skills 0.1.0
```

---

## Phase 2: Data Layer

**Goal:** Registry, cache, and state management.

### 2.1 Create Registry Manager

File: `home/.local/lib/ruby/skills/registry.rb`

Responsibilities:
- Load/save registry.yml
- CRUD operations for skill entries
- Check if skill exists

### 2.2 Create Cache Manager

File: `home/.local/lib/ruby/skills/cache.rb`

Responsibilities:
- Load/save search.yml
- Store search results
- Lookup by ID
- Clear cache

### 2.3 Create State Manager

File: `home/.local/lib/ruby/skills/state.rb`

Responsibilities:
- Load/save state.yml
- Track installed skills
- Record install timestamps

### Verification

```bash
# Manual YAML manipulation should work
skills state  # Shows empty state
```

---

## Phase 3: Search

**Goal:** Claude-powered web search with caching.

### 3.1 Create Search Provider Interface

File: `home/.local/lib/ruby/skills/search.rb`

```ruby
module Skills
  class Search
    def initialize(config:)
      @config = config
      @provider = load_provider
    end

    def find(query)
      @provider.search(query, max_results: @config.search_max_results)
    end

    private

    def load_provider
      case @config.search_provider
      when 'claude_code'
        require 'skills/search/claude_code'
        Search::ClaudeCode.new
      when 'api'
        require 'skills/search/api'
        Search::Api.new(config: @config)
      else
        raise "Unknown search provider: #{@config.search_provider}"
      end
    end
  end
end
```

### 3.2 Create Claude Code Provider

File: `home/.local/lib/ruby/skills/search/claude_code.rb`

Responsibilities:
- Build prompt for skill discovery
- Execute `claude -p "..."` command
- Parse response into structured results
- Generate IDs for each result

Prompt template (rough):
```
Search the web for AI development skills, MCP servers, or Claude tools related to: {query}

For each result, provide:
- name: Human-readable name
- description: One-line description
- url: Source URL (GitHub, npm, etc.)
- install_type: One of 'mcp', 'skill_folder', 'script'
- install_cmd: Command to install (if applicable)

Return results as YAML list. Maximum {max} results.
```

### 3.3 Integrate with CLI

```ruby
class Find < Dry::CLI::Command
  desc "Search for skills via Claude"

  argument :query, required: true, desc: "Search query"
  option :max, type: :integer, default: 10, desc: "Maximum results"

  def call(query:, **options)
    # Search, cache results, display
  end
end

register "find", Find
```

### Verification

```bash
skills find "solana token development"
# Should show results and save to cache
```

---

## Phase 4: Installation

**Goal:** Install skills from registry or cache.

### 4.1 Create Installer Dispatcher

File: `home/.local/lib/ruby/skills/installer.rb`

```ruby
module Skills
  class Installer
    def initialize(config:, state:)
      @config = config
      @state = state
    end

    def install(skill)
      installer = case skill[:install_type]
      when 'mcp' then Installer::Mcp.new
      when 'skill_folder' then Installer::SkillFolder.new
      when 'script' then Installer::Script.new
      else
        raise "Unknown install type: #{skill[:install_type]}"
      end

      installer.install(skill)
      @state.mark_installed(skill[:id])
    end

    def uninstall(skill)
      # Reverse of install
    end
  end
end
```

### 4.2 Create MCP Installer

File: `home/.local/lib/ruby/skills/installer/mcp.rb`

```ruby
module Skills
  class Installer
    class Mcp
      def install(skill)
        cmd = skill[:install_cmd]
        system(cmd) or raise "Install failed: #{cmd}"
      end
    end
  end
end
```

### 4.3 Create SkillFolder Installer

File: `home/.local/lib/ruby/skills/installer/skill_folder.rb`

Clone repo to `~/.claude/skills/{id}/`

### 4.4 Create Script Installer

File: `home/.local/lib/ruby/skills/installer/script.rb`

Execute arbitrary install command.

### 4.5 Integrate with CLI

```ruby
class Install < Dry::CLI::Command
  desc "Install a skill"

  argument :id, required: true, desc: "Skill ID"
  option :yes, type: :boolean, aliases: ["-y"], desc: "Skip confirmation"

  def call(id:, **options)
    # Look up in registry, then cache
    # Prompt if cache-only (unless -y)
    # Execute install
    # Update state
  end
end

register "install", Install
```

### Verification

```bash
skills find "solana"
skills install solana-spl-a3f2b1c9 -y
skills state
# Should show installed skill
```

---

## Phase 5: Registry Management

**Goal:** Promote skills and manage shared registry.

### 5.1 Add Command

```ruby
class Add < Dry::CLI::Command
  desc "Add skill from cache to registry"

  argument :id, required: true, desc: "Skill ID"

  def call(id:, **)
    # Load from cache
    # Copy to registry
    # Confirm
  end
end

register "add", Add
```

### 5.2 Remove Command

```ruby
class Remove < Dry::CLI::Command
  desc "Remove skill from registry"

  argument :id, required: true, desc: "Skill ID"
  option :force, type: :boolean, desc: "Skip confirmation"

  def call(id:, **options)
    # Confirm (registry is shared!)
    # Remove from registry
  end
end

register "remove", Remove
```

### 5.3 List Command

```ruby
class List < Dry::CLI::Command
  desc "List skills"

  argument :pattern, required: false, desc: "Filter pattern"
  option :cache, type: :boolean, desc: "Include cache results"

  def call(pattern: nil, **options)
    # Show registry entries
    # Optionally show cache entries
    # Indicate source (registry/cache)
  end
end

register "list", List
```

### Verification

```bash
skills add solana-spl-a3f2b1c9
skills list
# Should show skill with [registry] indicator
```

---

## Phase 6: TUI Enhancement

**Goal:** Interactive selection and formatted output.

### 6.1 Create UI Module

File: `home/.local/lib/ruby/skills/ui.rb`

```ruby
require 'tty-prompt'
require 'tty-table'
require 'pastel'

module Skills
  class UI
    def initialize(config:)
      @prompt = TTY::Prompt.new
      @pastel = Pastel.new(enabled: config.colors?)
    end

    def select_skill(results)
      choices = results.map do |r|
        { name: "#{r[:name]} - #{r[:description]}", value: r[:id] }
      end
      @prompt.select("Select a skill:", choices)
    end

    def confirm(message)
      @prompt.yes?(message)
    end

    def skills_table(skills)
      table = TTY::Table.new(
        header: ['ID', 'Name', 'Source'],
        rows: skills.map { |s| [s[:id], s[:name], s[:source]] }
      )
      table.render(:unicode)
    end
  end
end
```

### 6.2 Integrate Interactive Mode

After `find`, show selection menu:
- Arrow keys to navigate
- Enter to install
- `a` to add to registry
- `q` to quit

### Verification

```bash
skills find "phoenix liveview"
# Should show interactive menu
```

---

## Phase 7: Polish

**Goal:** Shell integration, documentation, tests.

### 7.1 Zsh Aliases

File: `home/.config/zsh/skills.zsh`

```zsh
# Skills CLI aliases
alias sf="skills find"
alias si="skills install"
alias sl="skills list"
alias ss="skills show"
alias sst="skills state"
```

### 7.2 Default Config

File: `home/.config/skills/config.yml`

```yaml
search:
  provider: claude_code
  max_results: 10

ui:
  interactive: true
  colors: true
```

### 7.3 Seed Registry

File: `home/.local/share/skills/registry.yml`

Start with a few known-good skills to demonstrate the format.

### 7.4 Install Script

File: `install.sh`

```bash
install_macos() {
  :
}

install_linux() {
  :
}

post_install() {
  source <(mise activate bash)
  install_gem dry-cli tty-prompt tty-table pastel
}
```

---

## Acceptance Criteria

- [ ] `skills find "query"` searches web via Claude, caches results
- [ ] `skills list` shows registry entries
- [ ] `skills install ID` installs from registry or cache
- [ ] `skills add ID` promotes cache entry to registry
- [ ] `skills state` shows locally installed skills
- [ ] Interactive TUI works for find results
- [ ] Shell aliases configured
- [ ] Works on macOS (primary dev environment)
