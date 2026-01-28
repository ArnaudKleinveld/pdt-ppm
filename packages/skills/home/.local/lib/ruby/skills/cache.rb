# frozen_string_literal: true

require 'yaml'
require 'time'

module Skills
  class Cache
    def initialize(config:)
      @config = config
      @data = load_data
    end

    def query
      @data['query']
    end

    def searched_at
      @data['searched_at']
    end

    def provider
      @data['provider']
    end

    def results
      @data['results'] || {}
    end

    def find(id)
      results[id]
    end

    def exists?(id)
      results.key?(id)
    end

    def store(query:, provider:, results:)
      @data = {
        'query' => query,
        'searched_at' => Time.now.utc.iso8601,
        'provider' => provider,
        'results' => results.transform_keys(&:to_s).transform_values { |v| v.transform_keys(&:to_s) }
      }
      save_data
    end

    def clear
      @data = {}
      path = @config.cache_path
      File.delete(path) if File.exist?(path)
    end

    def empty?
      results.empty?
    end

    def search(pattern)
      return results if pattern.nil? || pattern.empty?

      regex = Regexp.new(pattern, Regexp::IGNORECASE)
      results.select do |id, skill|
        id.match?(regex) ||
          skill['name']&.match?(regex) ||
          skill['description']&.match?(regex) ||
          skill['tags']&.any? { |t| t.match?(regex) }
      end
    end

    def reload
      @data = load_data
    end

    private

    def load_data
      path = @config.cache_path
      return {} unless File.exist?(path)

      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse cache: #{e.message}"
      {}
    end

    def save_data
      FileUtils.mkdir_p(File.dirname(@config.cache_path))
      File.write(@config.cache_path, YAML.dump(@data))
    end
  end
end
