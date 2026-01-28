# frozen_string_literal: true

require 'yaml'
require 'time'

module Skills
  class State
    def initialize(config:)
      @config = config
      @data = load_data
    end

    def installed
      @data['installed'] || {}
    end

    def find(id)
      installed[id]
    end

    def installed?(id)
      installed.key?(id)
    end

    def mark_installed(id, source:, install_path: nil)
      entry = {
        'id' => id,
        'installed_at' => Time.now.utc.iso8601,
        'source' => source
      }
      entry['install_path'] = install_path if install_path

      @data['installed'] ||= {}
      @data['installed'][id] = entry
      save_data
      entry
    end

    def mark_uninstalled(id)
      return false unless installed?(id)

      @data['installed'].delete(id)
      save_data
      true
    end

    def count
      installed.size
    end

    def reload
      @data = load_data
    end

    private

    def load_data
      path = @config.state_path
      return { 'installed' => {} } unless File.exist?(path)

      YAML.load_file(path) || { 'installed' => {} }
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse state: #{e.message}"
      { 'installed' => {} }
    end

    def save_data
      FileUtils.mkdir_p(File.dirname(@config.state_path))
      File.write(@config.state_path, YAML.dump(@data))
    end
  end
end
