# frozen_string_literal: true

require 'yaml'
require 'time'

module Skills
  class Registry
    def initialize(config:)
      @config = config
      @data = load_data
    end

    def all
      @data['skills'] || {}
    end

    def find(id)
      all[id]
    end

    def exists?(id)
      all.key?(id)
    end

    def add(skill)
      skill = skill.transform_keys(&:to_s)
      skill['added_at'] ||= Time.now.utc.iso8601
      @data['skills'] ||= {}
      @data['skills'][skill['id']] = skill
      save_data
      skill
    end

    def remove(id)
      return false unless exists?(id)

      @data['skills'].delete(id)
      save_data
      true
    end

    def search(pattern)
      return all if pattern.nil? || pattern.empty?

      regex = Regexp.new(pattern, Regexp::IGNORECASE)
      all.select do |id, skill|
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
      path = @config.registry_path
      return { 'skills' => {} } unless File.exist?(path)

      YAML.load_file(path) || { 'skills' => {} }
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse registry: #{e.message}"
      { 'skills' => {} }
    end

    def save_data
      File.write(@config.registry_path, YAML.dump(@data))
    end
  end
end
