# frozen_string_literal: true

require 'yaml'
require 'pathname'
require 'fileutils'
require 'thor'

module PimProfile
  # Deep merge utility for configuration hashes
  module DeepMerge
    def self.merge(base, overlay)
      return overlay.dup if base.nil?
      return base.dup if overlay.nil?

      base.merge(overlay) do |_key, old_val, new_val|
        if new_val.nil?
          old_val
        elsif old_val.is_a?(Hash) && new_val.is_a?(Hash)
          merge(old_val, new_val)
        else
          new_val
        end
      end
    end
  end

  # Configuration loader for pim-profile
  class Config
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')
    GLOBAL_CONFIG_D = File.join(GLOBAL_CONFIG_DIR, 'profiles.d')

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @profiles = load_profiles
    end

    def profiles
      @profiles
    end

    def profile(name)
      name = name.to_s
      default_profile = @profiles['default'] || {}

      if name == 'default' || name.empty?
        default_profile
      else
        DeepMerge.merge(default_profile, @profiles[name] || {})
      end
    end

    def profile_names
      @profiles.keys.sort
    end

    def save_profile(key, profile_data)
      FileUtils.mkdir_p(GLOBAL_CONFIG_D)
      File.write(File.join(GLOBAL_CONFIG_D, "#{key}.yml"), YAML.dump({ key => profile_data }))
    end

    private

    def load_profiles
      profiles = {}

      # Load from profiles.d/*.yml (each file contains profile entries directly)
      load_profiles_d(GLOBAL_CONFIG_D).each do |fragment|
        profiles = DeepMerge.merge(profiles, fragment)
      end

      # Load from project profiles.yml (entries directly, no wrapper)
      project_file = File.join(@project_dir, 'profiles.yml')
      profiles = DeepMerge.merge(profiles, load_yaml(project_file))

      profiles
    end

    def load_yaml(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse #{path}: #{e.message}"
      {}
    end

    def load_profiles_d(dir)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.yml')).sort.map do |file|
        load_yaml(file)
      end
    end
  end

  # Core profile management logic
  class Manager
    PROFILE_FIELDS = %w[
      hostname
      username
      password
      timezone
      domain
      locale
      keyboard
      packages
      authorized_keys_url
    ].freeze

    def initialize(config: nil, project_dir: Dir.pwd)
      @config_obj = config || Config.new(project_dir: project_dir)
    end

    def profiles
      @config_obj.profiles
    end

    def profile(name)
      @config_obj.profile(name)
    end

    def profile_names
      @config_obj.profile_names
    end

    def list(long: false)
      if profiles.empty?
        puts 'No profiles configured. Use "pim profile add" to add some.'
        return
      end

      if long
        max_name_len = profile_names.map(&:length).max
        profile_names.each do |name|
          profile_data = profile(name)
          hostname = profile_data['hostname'] || '-'
          username = profile_data['username'] || '-'
          puts "#{name.ljust(max_name_len)}  #{hostname}  #{username}"
        end
      else
        profile_names.each { |name| puts name }
      end
    end

    def show(name)
      profile_data = profile(name)

      if profile_data.empty? && name != 'default'
        puts "Error: Profile '#{name}' not found"
        return false
      end

      puts "Profile: #{name}"
      puts

      puts "Configuration:"
      if profile_data.empty?
        puts "  (no configuration)"
      else
        profile_data.each do |key, value|
          puts "  #{key}: #{value}"
        end
      end

      puts
      puts "Templates:"
      preseed = find_template('preseeds.d', "#{name}.cfg.erb") ||
                (name != 'default' && find_template('preseeds.d', 'default.cfg.erb'))
      install = find_template('installs.d', "#{name}.sh") ||
                (name != 'default' && find_template('installs.d', 'default.sh'))
      puts "  Preseed: #{preseed || '(not found)'}"
      puts "  Install: #{install || '(not found)'}"
      true
    end

    def add
      puts "Add New Profile\n\n"

      print 'Profile name: '
      name = $stdin.gets.chomp

      if name.empty?
        puts 'Error: Profile name is required'
        return false
      end

      if profiles.key?(name)
        print "Profile '#{name}' already exists. Overwrite? (y/N) "
        response = $stdin.gets.chomp
        return false unless response.downcase == 'y'
      end

      profile_data = {}

      PROFILE_FIELDS.each do |field|
        print "#{field}: "
        value = $stdin.gets.chomp
        profile_data[field] = value unless value.empty?
      end

      if profile_data.empty?
        puts "\nNo fields provided. Profile not created."
        return false
      end

      puts "\nCreating profile: #{name}\n\n"
      profile_data.each do |key, value|
        puts "  #{key}: #{value}"
      end

      @config_obj.save_profile(name, profile_data)

      puts "\nOK Profile saved to profiles.d/#{name}.yml"
      true
    end

    private

    def find_template(subdir, filename)
      xdg_config_home = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
      global_config_dir = File.join(xdg_config_home, 'pim')

      # 1. Project directory
      project_path = File.join(Dir.pwd, subdir, filename)
      return project_path if File.exist?(project_path)

      # 2. Global config directory
      global_path = File.join(global_config_dir, subdir, filename)
      return global_path if File.exist?(global_path)

      nil
    end
  end

  # CLI interface for pim-profile
  class CLI < Thor
    def self.exit_on_failure? = true
    remove_command :tree

    desc 'list', 'List profiles'
    option :long, type: :boolean, default: false, aliases: '-l', desc: 'Long format with hostname and username'
    map 'ls' => :list
    def list
      manager.list(long: options[:long])
    end

    desc 'show NAME', 'Show details of a profile'
    def show(name)
      manager.show(name)
    end

    desc 'add', 'Add a new profile interactively'
    def add
      manager.add
    end

    private

    def manager
      @manager ||= Manager.new
    end
  end
end
