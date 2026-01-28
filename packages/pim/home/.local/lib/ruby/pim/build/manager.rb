# frozen_string_literal: true

require_relative '../build'
require_relative '../registry'
require_relative '../qemu'
require_relative 'local_builder'

module PimBuild
  # Build manager - orchestrates the build process
  class Manager
    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @config = Config.new(project_dir: project_dir)
      @resolver = ArchitectureResolver.new(config: @config)
      @cache = CacheManager.new(config: @config, project_dir: project_dir)
      @script_loader = ScriptLoader.new(project_dir: project_dir)
    end

    # Execute a build
    def build(profile_name, arch:, force: false)
      profile_name = profile_name.to_s
      arch = @resolver.normalize(arch)

      puts "Building #{profile_name} for #{arch}"
      puts

      # Check dependencies
      check_dependencies!

      # Load profile
      profile_data, profile = load_profile(profile_name)

      # Verify architecture is supported
      verify_architecture(profile_data, arch)

      # Select builder
      builder_info = @resolver.select_builder(arch)

      # Resolve ISO
      iso_key, iso_path, iso_checksum = resolve_iso(arch)

      # Resolve scripts
      script_names = profile_data['scripts'] || %w[base finalize]
      scripts = resolve_scripts(script_names)

      # Calculate cache key
      cache_key = @cache.cache_key(
        profile_data: profile_data,
        scripts: scripts,
        iso_checksum: iso_checksum,
        arch: arch
      )

      puts "Profile:    #{profile_name}"
      puts "Arch:       #{arch}"
      puts "Builder:    #{builder_info[:type]}"
      puts "ISO:        #{iso_key}"
      puts "Scripts:    #{script_names.join(', ')}"
      puts "Cache key:  #{cache_key}"
      puts

      # Check cache
      unless force
        if cached = @cache.cached_image(profile: profile_name, arch: arch, cache_key: cache_key)
          puts "Cache hit: #{cached}"
          puts "Use --force to rebuild"
          return cached
        end
      end

      # Execute build based on builder type
      case builder_info[:type]
      when :local
        local_build(
          profile: profile,
          profile_name: profile_name,
          arch: arch,
          iso_key: iso_key,
          iso_path: iso_path,
          cache_key: cache_key,
          scripts: scripts
        )
      when :remote
        remote_build(
          builder_info: builder_info,
          profile: profile,
          profile_name: profile_name,
          arch: arch,
          iso_key: iso_key,
          cache_key: cache_key,
          scripts: scripts
        )
      else
        raise "Unknown builder type: #{builder_info[:type]}"
      end
    end

    # Dry run - show what would happen
    def dry_run(profile_name, arch:)
      profile_name = profile_name.to_s
      arch = @resolver.normalize(arch)

      puts "Dry run: #{profile_name} for #{arch}"
      puts

      # Check dependencies
      missing = PimQemu.check_dependencies
      if missing.any?
        puts "Missing dependencies: #{missing.join(', ')}"
        puts "(would fail)"
        puts
      end

      # Load profile
      profile_data, profile = load_profile(profile_name)

      # Verify architecture
      architectures = profile_data['architectures']
      if architectures && !architectures.include?(arch)
        puts "Warning: #{arch} not in profile's architectures: #{architectures.join(', ')}"
      end

      # Select builder
      builder_info = @resolver.select_builder(arch)

      # Resolve ISO
      iso_key, iso_path, iso_checksum = resolve_iso(arch)

      # Resolve scripts
      script_names = profile_data['scripts'] || %w[base finalize]
      begin
        scripts = resolve_scripts(script_names)
      rescue StandardError => e
        puts "Warning: #{e.message}"
        scripts = []
      end

      # Calculate cache key
      cache_key = @cache.cache_key(
        profile_data: profile_data,
        scripts: scripts,
        iso_checksum: iso_checksum,
        arch: arch
      )

      puts "Configuration:"
      puts "  Profile:      #{profile_name}"
      puts "  Architecture: #{arch}"
      puts "  Builder:      #{builder_info[:type]}#{builder_info[:name] ? " (#{builder_info[:name]})" : ''}"
      puts "  Image dir:    #{@config.image_dir}"
      puts "  Disk size:    #{profile_data.dig('build', 'disk_size') || @config.disk_size}"
      puts "  Memory:       #{profile_data.dig('build', 'memory') || @config.memory} MB"
      puts "  CPUs:         #{profile_data.dig('build', 'cpus') || @config.cpus}"
      puts

      puts "ISO:"
      puts "  Key:      #{iso_key}"
      puts "  Path:     #{iso_path}"
      puts "  Exists:   #{File.exist?(iso_path) ? 'yes' : 'NO - will need download'}"
      puts "  Checksum: #{iso_checksum[0..40]}..."
      puts

      puts "Scripts (#{scripts.size}):"
      script_names.each_with_index do |name, i|
        path = scripts[i] rescue nil
        status = path ? (File.exist?(path) ? 'OK' : 'MISSING') : 'NOT FOUND'
        puts "  #{name}: #{status}"
        puts "    #{path}" if path
      end
      puts

      puts "Cache:"
      puts "  Key: #{cache_key}"
      cached = @cache.cached_image(profile: profile_name, arch: arch, cache_key: cache_key)
      if cached
        puts "  Status: HIT - #{cached}"
        puts "  Would skip build (use --force to override)"
      else
        puts "  Status: MISS - will build"
      end
      puts

      puts "Build steps:"
      puts "  1. Create disk image (#{profile_data.dig('build', 'disk_size') || @config.disk_size})"
      puts "  2. Start preseed server"
      puts "  3. Start QEMU with ISO boot"
      puts "  4. Wait for SSH (timeout: #{@config.ssh_timeout}s)"
      puts "  5. Run provisioning scripts"
      puts "  6. Finalize image (clean cloud-init, truncate machine-id)"
      puts "  7. Shutdown VM"
      puts "  8. Register in registry"
    end

    private

    def check_dependencies!
      missing = PimQemu.check_dependencies
      return if missing.empty?

      puts "Missing dependencies: #{missing.join(', ')}"
      puts "Install with: brew install qemu"
      exit 1
    end

    def load_profile(profile_name)
      # Use existing Pim::Config and Pim::Profile
      pim_config = Pim::Config.new(project_dir: @project_dir)
      profile_data = pim_config.profile(profile_name)

      if profile_data.empty? && profile_name != 'default'
        puts "Error: Profile '#{profile_name}' not found"
        puts "Available profiles: #{pim_config.profile_names.join(', ')}"
        exit 1
      end

      profile = Pim::Profile.new(profile_name, profile_data, project_dir: @project_dir)

      [profile_data, profile]
    end

    def verify_architecture(profile_data, arch)
      architectures = profile_data['architectures']
      return unless architectures

      unless architectures.include?(arch)
        puts "Error: Profile does not support #{arch}"
        puts "Supported architectures: #{architectures.join(', ')}"
        exit 1
      end
    end

    def resolve_iso(arch)
      iso_config = PimIso::Config.new(project_dir: @project_dir)
      iso_manager = PimIso::Manager.new(config: iso_config)

      # Find ISO matching architecture
      iso_key = nil
      iso_data = nil

      iso_config.isos.each do |key, data|
        iso_arch = data['architecture']&.downcase
        # Normalize architecture names
        iso_arch = 'arm64' if iso_arch == 'aarch64'
        iso_arch = 'x86_64' if iso_arch == 'amd64'

        if iso_arch == arch
          iso_key = key
          iso_data = data
          break
        end
      end

      unless iso_key
        puts "Error: No ISO found for architecture: #{arch}"
        puts "Available ISOs:"
        iso_config.isos.each do |key, data|
          puts "  #{key}: #{data['architecture']}"
        end
        exit 1
      end

      filename = iso_data['filename'] || "#{iso_key}.iso"
      iso_path = File.join(iso_manager.iso_dir, filename)

      unless File.exist?(iso_path)
        puts "ISO not downloaded: #{iso_key}"
        puts "Run: pim iso download #{iso_key}"
        exit 1
      end

      checksum = iso_data['checksum'] || ''

      [iso_key, iso_path.to_s, checksum]
    end

    def resolve_scripts(script_names)
      @script_loader.resolve_scripts(script_names)
    end

    def local_build(profile:, profile_name:, arch:, iso_key:, iso_path:, cache_key:, scripts:)
      builder = LocalBuilder.new(
        config: @config,
        profile: profile,
        profile_name: profile_name,
        arch: arch,
        iso_path: iso_path,
        iso_key: iso_key
      )

      builder.build(cache_key: cache_key, scripts: scripts)
    end

    def remote_build(builder_info:, profile:, profile_name:, arch:, iso_key:, cache_key:, scripts:)
      puts "Remote builds not yet implemented"
      puts "Builder: #{builder_info[:name]}"
      puts "Host: #{builder_info[:config]['host']}"
      exit 1
    end
  end
end
