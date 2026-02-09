# frozen_string_literal: true

require 'thor'
require 'yaml'
require 'fileutils'

module PimConfig
  # CLI interface for pim config subcommand
  class CLI < Thor
    def self.exit_on_failure? = true
    remove_command :tree

    desc 'list', 'List all configuration values'
    def list
      config = Pim::Config.new
      flatten(config.runtime_config).each do |key, value|
        puts "#{key}=#{value}"
      end
    end
    map 'ls' => :list

    desc 'get KEY', 'Get a configuration value by dot-notation key'
    def get(key)
      config = Pim::Config.new
      parts = key.split('.')
      value = config.runtime_config.dig(*parts)

      if value.nil?
        $stderr.puts "Error: key '#{key}' not found"
        exit 1
      end

      if value.is_a?(Hash)
        flatten(value, key).each do |k, v|
          puts "#{k}=#{v}"
        end
      else
        puts value
      end
    end

    desc 'set KEY VALUE', 'Set a configuration value'
    option :project, type: :boolean, default: false, desc: 'Write to project pim.yml instead of global'
    def set(key, value)
      target = if options[:project]
                 File.join(Dir.pwd, 'pim.yml')
               else
                 File.join(Pim::Config::GLOBAL_CONFIG_DIR, 'pim.yml')
               end

      data = if File.exist?(target)
               YAML.load_file(target) || {}
             else
               {}
             end

      parts = key.split('.')
      coerced = coerce(value)

      # Build nested hash and set value
      current = data
      parts[0..-2].each do |part|
        current[part] ||= {}
        current = current[part]
      end
      current[parts.last] = coerced

      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, YAML.dump(data))

      puts "#{key}=#{coerced}"
    end

    private

    def flatten(hash, prefix = nil)
      result = []
      hash.each do |key, value|
        full_key = prefix ? "#{prefix}.#{key}" : key.to_s
        if value.is_a?(Hash)
          result.concat(flatten(value, full_key))
        else
          result << [full_key, value]
        end
      end
      result
    end

    def coerce(value)
      case value
      when /\A-?\d+\z/
        value.to_i
      when /\A-?\d+\.\d+\z/
        value.to_f
      when 'true'
        true
      when 'false'
        false
      else
        value
      end
    end
  end
end
