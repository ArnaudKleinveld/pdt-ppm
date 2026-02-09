# frozen_string_literal: true

require 'yaml'
require 'digest'
require 'pathname'
require 'fileutils'
require 'thor'

require_relative 'registry'

module PimBuild
  XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
  XDG_DATA_HOME = ENV.fetch('XDG_DATA_HOME', File.expand_path('~/.local/share'))
  GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')

  # Build configuration loader
  class Config
    DEFAULT_BUILD_CONFIG = {
      'image_dir' => File.join(XDG_DATA_HOME, 'pim', 'images'),
      'disk_size' => '20G',
      'memory' => 2048,
      'cpus' => 2,
      'ssh' => {
        'user' => 'ansible',
        'timeout' => 1800,
        'port' => 2222
      },
      'builders' => {}
    }.freeze

    attr_reader :build_config

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @runtime_config = load_runtime_config
      @build_config = load_build_config
    end

    def image_dir
      dir = @build_config['image_dir']
      expanded = dir.gsub('$HOME', Dir.home)
                    .gsub('$XDG_DATA_HOME', XDG_DATA_HOME)
                    .gsub('~', Dir.home)
      Pathname.new(File.expand_path(expanded))
    end

    def disk_size
      @build_config['disk_size']
    end

    def memory
      @build_config['memory']
    end

    def cpus
      @build_config['cpus']
    end

    def ssh_user
      @build_config.dig('ssh', 'user') || 'ansible'
    end

    def ssh_timeout
      @build_config.dig('ssh', 'timeout') || 1800
    end

    def ssh_port
      @build_config.dig('ssh', 'port') || 2222
    end

    def builder_for(arch)
      @build_config.dig('builders', arch) || 'local'
    end

    def remote_builders
      @build_config['remotes'] || {}
    end

    private

    def load_runtime_config
      config = {}

      global_file = File.join(GLOBAL_CONFIG_DIR, 'pim.yml')
      config = deep_merge(config, load_yaml(global_file))

      project_file = File.join(@project_dir, 'pim.yml')
      config = deep_merge(config, load_yaml(project_file))

      config
    end

    def load_build_config
      deep_merge(DEFAULT_BUILD_CONFIG.dup, @runtime_config['build'] || {})
    end

    def load_yaml(path)
      return {} unless File.exist?(path)

      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse #{path}: #{e.message}"
      {}
    end

    def deep_merge(base, overlay)
      return overlay.dup if base.nil?
      return base.dup if overlay.nil?

      base.merge(overlay) do |_key, old_val, new_val|
        if new_val.nil?
          old_val
        elsif old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
    end
  end

  # Detect and route architecture to appropriate builder
  class ArchitectureResolver
    ARCH_MAP = {
      'arm64' => 'arm64',
      'aarch64' => 'arm64',
      'x86_64' => 'x86_64',
      'amd64' => 'x86_64'
    }.freeze

    def initialize(config: nil)
      @config = config || Config.new
    end

    def host_arch
      raw = `uname -m`.strip.downcase
      ARCH_MAP[raw] || raw
    end

    def normalize(arch)
      ARCH_MAP[arch.to_s.downcase] || arch.to_s.downcase
    end

    def can_build_locally?(target_arch)
      normalize(target_arch) == host_arch
    end

    def builder_type(target_arch)
      @config.builder_for(normalize(target_arch))
    end

    def select_builder(target_arch)
      normalized = normalize(target_arch)
      configured = @config.builder_for(normalized)

      case configured
      when 'local'
        if can_build_locally?(normalized)
          { type: :local, arch: normalized }
        else
          raise "Cannot build #{normalized} locally on #{host_arch} host"
        end
      when String
        # Remote builder name
        remote = @config.remote_builders[configured]
        raise "Unknown remote builder: #{configured}" unless remote

        { type: :remote, name: configured, config: remote, arch: normalized }
      else
        # Default: try local if possible, otherwise fail
        if can_build_locally?(normalized)
          { type: :local, arch: normalized }
        else
          raise "No builder configured for #{normalized} architecture"
        end
      end
    end
  end

  # Content-based cache key generation
  class CacheManager
    def initialize(config: nil, project_dir: Dir.pwd)
      @config = config || Config.new(project_dir: project_dir)
      @project_dir = project_dir
    end

    # Generate cache key from profile, scripts, and ISO
    def cache_key(profile_data:, scripts:, iso_checksum:, arch:)
      components = []

      # Profile data (sorted for consistency)
      profile_json = JSON.generate(sort_hash(profile_data))
      components << Digest::SHA256.hexdigest(profile_json)

      # Scripts content
      scripts.each do |script_path|
        if File.exist?(script_path)
          components << Digest::SHA256.file(script_path).hexdigest
        end
      end

      # ISO checksum
      components << iso_checksum.to_s.sub(/^sha\d+:/, '')

      # Architecture
      components << arch

      # Combined hash
      Digest::SHA256.hexdigest(components.join(':'))[0..15]
    end

    # Check if a cached image exists
    def cached?(profile:, arch:, cache_key:)
      registry = PimRegistry::Registry.new(image_dir: @config.image_dir)
      registry.cached?(profile: profile, arch: arch, cache_key: cache_key)
    end

    # Get cached image path if valid
    def cached_image(profile:, arch:, cache_key:)
      registry = PimRegistry::Registry.new(image_dir: @config.image_dir)
      entry = registry.find(profile: profile, arch: arch)

      return nil unless entry
      return nil unless entry['cache_key'] == cache_key
      return nil unless entry['path'] && File.exist?(entry['path'])

      entry['path']
    end

    private

    def sort_hash(obj)
      case obj
      when Hash
        obj.sort.to_h.transform_values { |v| sort_hash(v) }
      when Array
        obj.map { |v| sort_hash(v) }
      else
        obj
      end
    end
  end

  # Script loader for provisioning scripts
  class ScriptLoader
    SCRIPTS_DIR = 'scripts.d'

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
    end

    # Find script by name (follows naming convention with fallback)
    def find_script(name)
      find_file(SCRIPTS_DIR, "#{name}.sh")
    end

    # Resolve list of script names to paths
    def resolve_scripts(script_names)
      script_names.map do |name|
        path = find_script(name)
        raise "Script not found: #{name}.sh" unless path

        path
      end
    end

    # Get script content
    def script_content(name)
      path = find_script(name)
      return nil unless path

      File.read(path)
    end

    private

    def find_file(subdir, filename)
      # 1. Project directory
      project_path = File.join(@project_dir, subdir, filename)
      return project_path if File.exist?(project_path)

      # 2. Global config directory
      global_path = File.join(GLOBAL_CONFIG_DIR, subdir, filename)
      return global_path if File.exist?(global_path)

      nil
    end
  end

  # CLI for build commands
  class CLI < Thor
    def self.exit_on_failure? = true
    remove_command :tree

    desc 'run PROFILE', 'Build an image for the given profile'
    option :arch, type: :string, aliases: '-a', desc: 'Target architecture (arm64, x86_64)'
    option :force, type: :boolean, default: false, aliases: '-f', desc: 'Force rebuild ignoring cache'
    option :dry_run, type: :boolean, default: false, aliases: '-n', desc: 'Show what would be done'
    option :vnc, type: :numeric, default: nil, desc: 'Enable VNC display on port 5900+N (e.g. --vnc 0)'
    option :console, type: :boolean, default: false, aliases: '-c', desc: 'Stream serial console output to stdout'
    option :console_log, type: :string, default: nil, desc: 'Log serial console to file'
    def run_build(profile_name)
      require_relative 'build/manager'

      arch = options[:arch] || ArchitectureResolver.new.host_arch
      manager = PimBuild::Manager.new

      if options[:dry_run]
        manager.dry_run(profile_name, arch: arch)
      else
        manager.build(
          profile_name,
          arch: arch,
          force: options[:force],
          vnc: options[:vnc],
          console: options[:console],
          console_log: options[:console_log]
        )
      end
    end
    map 'run' => :run_build

    desc 'list', 'List built images'
    option :long, type: :boolean, default: false, aliases: '-l', desc: 'Long format with details'
    map 'ls' => :list
    def list
      config = Config.new
      registry = PimRegistry::Registry.new(image_dir: config.image_dir)

      entries = registry.list(long: options[:long])

      if entries.empty?
        puts "No images found in #{config.image_dir}"
        return
      end

      if options[:long]
        puts format('%-20s %-8s %-20s %10s  %s', 'PROFILE', 'ARCH', 'BUILT', 'SIZE', 'STATUS')
        puts '-' * 80
        entries.each do |entry|
          time_str = entry[:build_time] ? Time.parse(entry[:build_time]).strftime('%Y-%m-%d %H:%M') : '-'
          size_str = entry[:size] ? format_bytes(entry[:size]) : '-'
          status = entry[:exists] ? 'OK' : 'MISSING'
          puts format('%-20s %-8s %-20s %10s  %s', entry[:profile], entry[:arch], time_str, size_str, status)
        end
      else
        entries.each { |entry| puts entry[:key] }
      end
    end

    desc 'show PROFILE', 'Show details of a built image'
    option :arch, type: :string, aliases: '-a', desc: 'Architecture (defaults to host arch)'
    def show(profile_name)
      config = Config.new
      arch = options[:arch] || ArchitectureResolver.new.host_arch
      registry = PimRegistry::Registry.new(image_dir: config.image_dir)

      entry = registry.find(profile: profile_name, arch: arch)

      unless entry
        puts "No image found for #{profile_name}-#{arch}"
        exit 1
      end

      puts "Image: #{profile_name}-#{arch}"
      puts
      puts "Path:       #{entry['path']}"
      puts "Filename:   #{entry['filename']}"
      puts "Built:      #{entry['build_time']}"
      puts "Size:       #{entry['size'] ? format_bytes(entry['size']) : 'unknown'}"
      puts "Cache key:  #{entry['cache_key']}"
      puts "ISO:        #{entry['iso']}"
      puts "Exists:     #{File.exist?(entry['path']) ? 'yes' : 'NO - FILE MISSING'}"

      if entry['deployments']&.any?
        puts
        puts "Deployments:"
        entry['deployments'].each do |d|
          puts "  - #{d['target']} (#{d['target_type']}) at #{d['deployed_at']}"
        end
      end
    end

    desc 'clean', 'Clean cached images'
    option :orphaned, type: :boolean, default: false, desc: 'Only remove orphaned registry entries'
    option :all, type: :boolean, default: false, desc: 'Remove all cached images'
    def clean
      config = Config.new
      registry = PimRegistry::Registry.new(image_dir: config.image_dir)

      if options[:orphaned]
        removed = registry.clean_orphaned
        if removed.empty?
          puts 'No orphaned entries found'
        else
          puts "Removed #{removed.size} orphaned entries:"
          removed.each { |key| puts "  - #{key}" }
        end
      elsif options[:all]
        print "Remove all images in #{config.image_dir}? (y/N) "
        response = $stdin.gets.chomp
        return unless response.downcase == 'y'

        entries = registry.list
        entries.each do |entry|
          FileUtils.rm_f(entry[:path]) if entry[:path] && File.exist?(entry[:path])
          registry.unregister(profile: entry[:profile], arch: entry[:arch])
        end
        puts "Removed #{entries.size} images"
      else
        puts 'Use --orphaned to clean orphaned entries or --all to remove all images'
      end
    end

    desc 'status', 'Show build system status'
    def status
      config = Config.new
      resolver = ArchitectureResolver.new(config: config)

      puts 'Build System Status'
      puts
      puts "Host architecture: #{resolver.host_arch}"
      puts "Image directory:   #{config.image_dir}"
      puts "Disk size:         #{config.disk_size}"
      puts "Memory:            #{config.memory} MB"
      puts "CPUs:              #{config.cpus}"
      puts
      puts 'Builders:'

      %w[arm64 x86_64].each do |arch|
        builder = config.builder_for(arch)
        can_local = resolver.can_build_locally?(arch)
        status = case builder
                 when 'local'
                   can_local ? 'local (available)' : 'local (unavailable - wrong arch)'
                 else
                   "remote: #{builder}"
                 end
        puts "  #{arch}: #{status}"
      end

      if config.remote_builders.any?
        puts
        puts 'Remote builders:'
        config.remote_builders.each do |name, remote|
          puts "  #{name}: #{remote['host']}:#{remote['port'] || 22}"
        end
      end

      registry = PimRegistry::Registry.new(image_dir: config.image_dir)
      images = registry.list
      puts
      puts "Cached images: #{images.size}"
    end

    private

    def format_bytes(bytes)
      units = %w[B KB MB GB TB]
      return '0 B' if bytes.nil? || bytes == 0

      exp = (Math.log(bytes) / Math.log(1024)).floor
      exp = [exp, units.size - 1].min

      format('%.1f %s', bytes.to_f / (1024**exp), units[exp])
    end
  end
end
