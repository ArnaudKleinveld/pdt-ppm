# frozen_string_literal: true

require 'yaml'
require 'fileutils'

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
      @config.dig('paths', 'registry') || File.join(DATA_DIR, 'registry.yml')
    end

    def state_path
      @config.dig('paths', 'state') || File.join(DATA_DIR, 'state.yml')
    end

    def cache_path
      @config.dig('paths', 'cache') || File.join(CACHE_DIR, 'search.yml')
    end

    def skills_dir
      File.expand_path('~/.claude/skills')
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
