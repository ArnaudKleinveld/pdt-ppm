# frozen_string_literal: true

require 'yaml'
require 'pathname'
require 'digest'
require 'fileutils'
require 'erb'
require 'open3'
require 'thor'
require 'json'

module PimPacker
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

  # Configuration loader for targets
  class TargetConfig
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')
    GLOBAL_CONFIG_D = File.join(GLOBAL_CONFIG_DIR, 'targets.d')

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @targets = load_targets
    end

    def targets
      @targets
    end

    def target(name)
      name = name.to_s
      default_target = @targets['default'] || {}

      if name == 'default' || name.empty?
        default_target
      else
        DeepMerge.merge(default_target, @targets[name] || {})
      end
    end

    def target_names
      @targets.keys.reject { |k| k == 'default' }.sort
    end

    private

    def load_targets
      targets = {}

      load_targets_d(GLOBAL_CONFIG_D).each do |fragment|
        targets = DeepMerge.merge(targets, fragment)
      end

      project_file = File.join(@project_dir, 'targets.yml')
      targets = DeepMerge.merge(targets, load_yaml(project_file))

      targets
    end

    def load_yaml(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse #{path}: #{e.message}"
      {}
    end

    def load_targets_d(dir)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.yml')).sort.map do |file|
        load_yaml(file)
      end
    end
  end

  # Configuration loader for builds
  class BuildConfig
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')
    GLOBAL_CONFIG_D = File.join(GLOBAL_CONFIG_DIR, 'builds.d')

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @builds = load_builds
    end

    def builds
      @builds
    end

    def build(name)
      @builds[name.to_s]
    end

    def build_names
      @builds.keys.sort
    end

    def matching_builds(pattern)
      if pattern.include?('*')
        regex = Regexp.new("^#{pattern.gsub('*', '.*')}$")
        build_names.select { |name| name.match?(regex) }
      else
        build_names.select { |name| name == pattern }
      end
    end

    def save_build(name, build_data)
      FileUtils.mkdir_p(GLOBAL_CONFIG_D)
      File.write(File.join(GLOBAL_CONFIG_D, "#{name}.yml"), YAML.dump({ name => build_data }))
    end

    private

    def load_builds
      builds = {}

      load_builds_d(GLOBAL_CONFIG_D).each do |fragment|
        builds = DeepMerge.merge(builds, fragment)
      end

      project_file = File.join(@project_dir, 'builds.yml')
      builds = DeepMerge.merge(builds, load_yaml(project_file))

      builds
    end

    def load_yaml(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse #{path}: #{e.message}"
      {}
    end

    def load_builds_d(dir)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.yml')).sort.map do |file|
        load_yaml(file)
      end
    end
  end

  # Resolves and merges all configuration for a build
  class BuildResolver
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @build_config = BuildConfig.new(project_dir: project_dir)
      @target_config = TargetConfig.new(project_dir: project_dir)
      @profile_config = PimProfile::Config.new(project_dir: project_dir)
      @iso_config = PimIso::Config.new(project_dir: project_dir)
    end

    attr_reader :build_config, :target_config, :profile_config, :iso_config

    def resolve(build_name)
      build = @build_config.build(build_name)
      return nil unless build

      iso_key = build['iso']
      profile_name = build['profile'] || 'default'
      target_name = build['target']
      base_image = build['base_image']

      iso_data = iso_key ? @iso_config.isos[iso_key] : nil
      profile_data = @profile_config.profile(profile_name)
      target_data = @target_config.target(target_name)

      # Validate required fields based on target type
      if target_name == 'docker'
        unless base_image
          raise "Build '#{build_name}' requires 'base_image' for docker target"
        end
      else
        unless iso_data
          raise "Build '#{build_name}' references unknown ISO '#{iso_key}'"
        end
      end

      unless target_data && !target_data.empty?
        raise "Build '#{build_name}' references unknown target '#{target_name}'"
      end

      # Merge everything
      resolved = {}
      resolved = DeepMerge.merge(resolved, iso_data) if iso_data
      resolved = DeepMerge.merge(resolved, profile_data)
      resolved = DeepMerge.merge(resolved, target_data)
      resolved = DeepMerge.merge(resolved, build.fetch('overrides', {}))

      # Add metadata
      resolved['_build_name'] = build_name
      resolved['_iso_key'] = iso_key
      resolved['_profile_name'] = profile_name
      resolved['_target_name'] = target_name
      resolved['_base_image'] = base_image

      # Resolve preseed/install template names
      resolved['_preseed_name'] = build['preseed'] || profile_name
      resolved['_install_name'] = build['install'] || profile_name

      resolved
    end

    def compute_image_cache_key(resolved)
      # Cache key for qcow2 is based on iso + profile + preseed + install content
      components = []

      # ISO checksum
      components << resolved['checksum'] if resolved['checksum']

      # Profile content (serialize relevant keys)
      profile_keys = %w[username password fullname locale keyboard hostname domain
                        mirror_host mirror_path http_proxy timezone partitioning_method
                        partitioning_recipe tasksel packages grub_device authorized_keys_url]
      profile_content = profile_keys.map { |k| "#{k}=#{resolved[k]}" }.join("\n")
      components << Digest::SHA256.hexdigest(profile_content)

      # Preseed template content
      preseed_path = find_template('preseeds.d', "#{resolved['_preseed_name']}.cfg.erb")
      if preseed_path && File.exist?(preseed_path)
        components << Digest::SHA256.file(preseed_path).hexdigest
      end

      # Install script content
      install_path = find_template('installs.d', "#{resolved['_install_name']}.sh")
      if install_path && File.exist?(install_path)
        components << Digest::SHA256.file(install_path).hexdigest
      end

      Digest::SHA256.hexdigest(components.join(':'))[0..15]
    end

    private

    def find_template(subdir, filename)
      project_path = File.join(@project_dir, subdir, filename)
      return project_path if File.exist?(project_path)

      global_path = File.join(GLOBAL_CONFIG_DIR, subdir, filename)
      return global_path if File.exist?(global_path)

      nil
    end
  end

  # Handles rendering of templates
  class TemplateRenderer
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')
    TEMPLATES_DIR = File.join(GLOBAL_CONFIG_DIR, 'templates')

    def initialize(resolved_config, project_dir: Dir.pwd)
      @config = resolved_config
      @project_dir = project_dir
    end

    def render_preseed(output_path)
      template_path = find_config_template('preseeds.d', "#{@config['_preseed_name']}.cfg.erb")
      return nil unless template_path

      content = render_erb(template_path, @config)
      File.write(output_path, content)
      output_path
    end

    def render_install_script(output_path)
      template_path = find_config_template('installs.d', "#{@config['_install_name']}.sh")
      return nil unless template_path

      FileUtils.cp(template_path, output_path)
      output_path
    end

    def render_pkrvars(output_path, template_name: 'qemu')
      template_path = find_template("packer/#{template_name}.pkrvars.hcl.erb")
      return nil unless template_path

      content = render_erb(template_path, @config)
      File.write(output_path, content)
      output_path
    end

    def render_dockerfile(output_path)
      template_path = find_template("docker/Dockerfile.erb")
      return nil unless template_path

      content = render_erb(template_path, @config)
      File.write(output_path, content)
      output_path
    end

    def packer_template_path(template_name: 'qemu')
      find_template("packer/#{template_name}.pkr.hcl")
    end

    private

    def find_config_template(subdir, filename)
      project_path = File.join(@project_dir, subdir, filename)
      return project_path if File.exist?(project_path)

      global_path = File.join(GLOBAL_CONFIG_DIR, subdir, filename)
      return global_path if File.exist?(global_path)

      nil
    end

    def find_template(relative_path)
      project_path = File.join(@project_dir, 'templates', relative_path)
      return project_path if File.exist?(project_path)

      global_path = File.join(TEMPLATES_DIR, relative_path)
      return global_path if File.exist?(global_path)

      nil
    end

    def render_erb(template_path, bindings_hash)
      template_content = File.read(template_path)
      
      # Add generated_at timestamp
      bindings_hash['_generated_at'] = Time.now.iso8601
      
      # Use a custom binding class that returns nil for undefined variables
      context = RenderContext.new(bindings_hash)
      
      template = ERB.new(template_content)
      template.result(context.get_binding)
    end
  end

  # Clean binding context for ERB rendering
  class RenderContext
    def initialize(hash)
      @data = {}
      hash.each do |key, value|
        @data[key.to_sym] = value
        # Define getter method for each key
        define_singleton_method(key.to_sym) { @data[key.to_sym] }
      end
    end

    def get_binding
      binding
    end

    # Handle undefined variables gracefully
    def method_missing(name, *args)
      nil
    end

    def respond_to_missing?(name, include_private = false)
      true
    end
  end

  # Cache manager for build artifacts
  class BuildCache
    XDG_CACHE_HOME = ENV.fetch('XDG_CACHE_HOME', File.expand_path('~/.cache'))
    CACHE_DIR = File.join(XDG_CACHE_HOME, 'pim', 'builds')
    IMAGES_DIR = File.join(XDG_CACHE_HOME, 'pim', 'builds', 'images')

    def initialize
      FileUtils.mkdir_p(CACHE_DIR)
      FileUtils.mkdir_p(IMAGES_DIR)
    end

    def build_dir(build_name)
      path = File.join(CACHE_DIR, build_name)
      FileUtils.mkdir_p(path)
      FileUtils.mkdir_p(File.join(path, 'rendered'))
      Pathname.new(path)
    end

    def rendered_dir(build_name)
      build_dir(build_name) / 'rendered'
    end

    def image_path(cache_key)
      Pathname.new(File.join(IMAGES_DIR, "#{cache_key}.qcow2"))
    end

    def image_exists?(cache_key)
      image_path(cache_key).exist?
    end

    def manifest_path(build_name)
      build_dir(build_name) / 'manifest.yml'
    end

    def load_manifest(build_name)
      path = manifest_path(build_name)
      return nil unless path.exist?
      YAML.load_file(path)
    rescue Psych::SyntaxError
      nil
    end

    def save_manifest(build_name, data)
      File.write(manifest_path(build_name), YAML.dump(data))
    end

    def clear(build_name)
      path = File.join(CACHE_DIR, build_name)
      FileUtils.rm_rf(path) if Dir.exist?(path)
    end

    def clear_all
      FileUtils.rm_rf(CACHE_DIR)
      FileUtils.mkdir_p(CACHE_DIR)
      FileUtils.mkdir_p(IMAGES_DIR)
    end
  end

  # Builds qcow2 images using Packer
  class QemuBuilder
    def initialize(resolved_config, cache: nil, iso_manager: nil)
      @config = resolved_config
      @cache = cache || BuildCache.new
      @iso_manager = iso_manager || PimIso::Manager.new
    end

    def build(output_path:, dry_run: false)
      build_name = @config['_build_name']
      rendered_dir = @cache.rendered_dir(build_name)

      # Ensure ISO is downloaded
      iso_key = @config['_iso_key']
      iso_path = @iso_manager.iso_dir / @config['filename']

      unless iso_path.exist?
        puts "Downloading ISO #{iso_key}..."
        @iso_manager.download(iso_key)
      end

      # Render templates
      renderer = TemplateRenderer.new(@config)

      preseed_path = rendered_dir / 'preseed.cfg'
      install_path = rendered_dir / 'install.sh'
      pkrvars_path = rendered_dir / 'variables.pkrvars.hcl'

      renderer.render_preseed(preseed_path)
      renderer.render_install_script(install_path)

      # Add paths to config for pkrvars rendering
      @config['_iso_path'] = iso_path.to_s
      @config['_preseed_path'] = preseed_path.to_s
      @config['_install_path'] = install_path.to_s
      @config['_output_path'] = output_path.to_s
      @config['_http_dir'] = rendered_dir.to_s

      renderer.render_pkrvars(pkrvars_path)

      packer_template = renderer.packer_template_path

      unless packer_template
        puts "Error: Packer template not found at templates/packer/qemu.pkr.hcl"
        return false
      end

      # Build packer command
      cmd = [
        'packer', 'build',
        '-var-file', pkrvars_path.to_s,
        packer_template
      ]

      if dry_run
        puts "\n=== DRY RUN ==="
        puts "\nRendered files:"
        puts "  preseed.cfg: #{preseed_path}"
        puts "  install.sh:  #{install_path}"
        puts "  pkrvars:     #{pkrvars_path}"
        puts "\nPacker command:"
        puts "  #{cmd.join(' ')}"
        puts "\nPreseed content:"
        puts '-' * 40
        puts File.read(preseed_path) if preseed_path.exist?
        puts "\nPkrvars content:"
        puts '-' * 40
        puts File.read(pkrvars_path) if pkrvars_path.exist?
        return true
      end

      puts "Running: #{cmd.join(' ')}"
      system(*cmd)
    end
  end

  # Builds AMIs directly on AWS using Packer amazon-ebs builder
  class AwsEbsBuilder
    def initialize(resolved_config, cache: nil)
      @config = resolved_config
      @cache = cache || BuildCache.new
    end

    def build(dry_run: false)
      build_name = @config['_build_name']
      rendered_dir = @cache.rendered_dir(build_name)

      renderer = TemplateRenderer.new(@config)
      pkrvars_path = rendered_dir / 'variables.pkrvars.hcl'

      renderer.render_pkrvars(pkrvars_path, template_name: 'aws-ebs')

      packer_template = renderer.packer_template_path(template_name: 'aws-ebs')

      unless packer_template
        puts "Error: Packer template not found at templates/packer/aws-ebs.pkr.hcl"
        return false
      end

      cmd = [
        'packer', 'build',
        '-var-file', pkrvars_path.to_s,
        packer_template
      ]

      if dry_run
        puts "\n=== DRY RUN ==="
        puts "\nRendered files:"
        puts "  pkrvars: #{pkrvars_path}"
        puts "\nPacker command:"
        puts "  #{cmd.join(' ')}"
        puts "\nPkrvars content:"
        puts '-' * 40
        puts File.read(pkrvars_path) if pkrvars_path.exist?
        return true
      end

      puts "Running: #{cmd.join(' ')}"
      system(*cmd)
    end
  end

  # Builds Docker images
  class DockerBuilder
    def initialize(resolved_config, cache: nil)
      @config = resolved_config
      @cache = cache || BuildCache.new
    end

    def build(dry_run: false)
      build_name = @config['_build_name']
      rendered_dir = @cache.rendered_dir(build_name)

      renderer = TemplateRenderer.new(@config)

      dockerfile_path = rendered_dir / 'Dockerfile'
      renderer.render_dockerfile(dockerfile_path)

      # Copy install script if it exists
      install_path = rendered_dir / 'install.sh'
      renderer.render_install_script(install_path)

      image_tag = @config['_build_name'].gsub(/[^a-zA-Z0-9_.-]/, '-')

      cmd = [
        'docker', 'build',
        '-t', image_tag,
        '-f', dockerfile_path.to_s,
        rendered_dir.to_s
      ]

      if dry_run
        puts "\n=== DRY RUN ==="
        puts "\nRendered files:"
        puts "  Dockerfile:  #{dockerfile_path}"
        puts "  install.sh:  #{install_path}" if install_path.exist?
        puts "\nDocker command:"
        puts "  #{cmd.join(' ')}"
        puts "\nDockerfile content:"
        puts '-' * 40
        puts File.read(dockerfile_path) if dockerfile_path.exist?
        return true
      end

      puts "Running: #{cmd.join(' ')}"
      system(*cmd)
    end
  end

  # Uploads qcow2 to Proxmox and creates template
  class ProxmoxCloneConverter
    def initialize(qcow2_path, resolved_config)
      @qcow2_path = qcow2_path
      @config = resolved_config
    end

    def convert(dry_run: false)
      vm_id = @config['proxmox_vmid'] || next_available_vmid
      vm_name = @config['vm_name'] || @config['_build_name']
      node = @config['proxmox_node'] || 'pve'
      storage = @config['proxmox_storage'] || 'local-lvm'
      memory = @config['memory'] || 2048
      cores = @config['cores'] || 2

      commands = [
        "qm create #{vm_id} --name '#{vm_name}' --memory #{memory} --cores #{cores} --net0 virtio,bridge=vmbr0",
        "qm importdisk #{vm_id} '#{@qcow2_path}' #{storage}",
        "qm set #{vm_id} --scsihw virtio-scsi-pci --scsi0 #{storage}:vm-#{vm_id}-disk-0",
        "qm set #{vm_id} --boot c --bootdisk scsi0",
        "qm set #{vm_id} --ide2 #{storage}:cloudinit",
        "qm set #{vm_id} --serial0 socket --vga serial0",
        "qm set #{vm_id} --agent enabled=1",
        "qm template #{vm_id}"
      ]

      if dry_run
        puts "\n=== DRY RUN: Proxmox Clone ==="
        puts "\nSource qcow2: #{@qcow2_path}"
        puts "Target VM ID: #{vm_id}"
        puts "VM Name: #{vm_name}"
        puts "\nCommands to execute:"
        commands.each { |cmd| puts "  #{cmd}" }
        return true
      end

      commands.each do |cmd|
        puts "Running: #{cmd}"
        unless system(cmd)
          puts "Error: Command failed"
          return false
        end
      end

      puts "\nTemplate created: #{vm_name} (ID: #{vm_id})"
      true
    end

    private

    def next_available_vmid
      # Default starting point, should query Proxmox API in production
      9000
    end
  end

  # Converts qcow2 to AMI and imports to AWS
  class AwsConverter
    def initialize(qcow2_path, resolved_config)
      @qcow2_path = qcow2_path
      @config = resolved_config
    end

    def convert(dry_run: false)
      raw_path = @qcow2_path.to_s.sub(/\.qcow2$/, '.raw')
      bucket = @config['aws_s3_bucket']
      region = @config['aws_region'] || 'us-east-1'
      ami_name = @config['vm_name'] || @config['_build_name']

      unless bucket
        puts "Error: aws_s3_bucket not configured in target"
        return false
      end

      commands = [
        "qemu-img convert -f qcow2 -O raw '#{@qcow2_path}' '#{raw_path}'",
        "aws s3 cp '#{raw_path}' 's3://#{bucket}/#{File.basename(raw_path)}'",
      ]

      # Container file for import-snapshot
      container_json = {
        "Description" => ami_name,
        "Format" => "raw",
        "UserBucket" => {
          "S3Bucket" => bucket,
          "S3Key" => File.basename(raw_path)
        }
      }

      if dry_run
        puts "\n=== DRY RUN: AWS AMI ==="
        puts "\nSource qcow2: #{@qcow2_path}"
        puts "Intermediate raw: #{raw_path}"
        puts "S3 bucket: #{bucket}"
        puts "Region: #{region}"
        puts "\nCommands to execute:"
        commands.each { |cmd| puts "  #{cmd}" }
        puts "\nThen: aws ec2 import-snapshot with container.json"
        puts "Then: aws ec2 register-image to create AMI"
        return true
      end

      commands.each do |cmd|
        puts "Running: #{cmd}"
        unless system(cmd)
          puts "Error: Command failed"
          return false
        end
      end

      # Import snapshot
      puts "Importing snapshot to AWS..."
      container_file = "/tmp/container-#{Process.pid}.json"
      File.write(container_file, JSON.pretty_generate(container_json))

      import_output = `aws ec2 import-snapshot --region #{region} --disk-container file://#{container_file} 2>&1`
      puts import_output

      # Note: In production, would poll for completion and register AMI
      puts "\nSnapshot import initiated. Use 'aws ec2 describe-import-snapshot-tasks' to monitor."
      true
    end
  end

  # Packages qcow2 for UTM
  class UtmConverter
    def initialize(qcow2_path, resolved_config)
      @qcow2_path = qcow2_path
      @config = resolved_config
    end

    def convert(dry_run: false)
      vm_name = @config['vm_name'] || @config['_build_name']
      output_dir = @config['utm_output_dir'] || File.expand_path('~/Documents/UTM')
      utm_path = File.join(output_dir, "#{vm_name}.utm")

      if dry_run
        puts "\n=== DRY RUN: UTM Package ==="
        puts "\nSource qcow2: #{@qcow2_path}"
        puts "Output: #{utm_path}"
        puts "\nWould create UTM bundle with qcow2 disk"
        return true
      end

      # UTM bundles are directories with specific structure
      FileUtils.mkdir_p(utm_path)
      FileUtils.mkdir_p(File.join(utm_path, 'Data'))

      # Copy qcow2 as the disk image
      disk_path = File.join(utm_path, 'Data', 'disk-0.qcow2')
      FileUtils.cp(@qcow2_path, disk_path)

      # Create minimal config.plist
      # Note: In production, would generate proper UTM config
      puts "Created UTM bundle at #{utm_path}"
      puts "Note: You may need to configure VM settings in UTM"
      true
    end
  end

  # Main build orchestrator
  class Manager
    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @resolver = BuildResolver.new(project_dir: project_dir)
      @cache = BuildCache.new
    end

    attr_reader :resolver, :cache

    def build(build_name, dry_run: false, no_cache: false)
      resolved = @resolver.resolve(build_name)

      unless resolved
        puts "Error: Build '#{build_name}' not found"
        return false
      end

      target = resolved['_target_name']
      puts "Building: #{build_name}"
      puts "  ISO:     #{resolved['_iso_key'] || 'N/A'}"
      puts "  Profile: #{resolved['_profile_name']}"
      puts "  Target:  #{target}"
      puts

      case target
      when 'docker'
        build_docker(resolved, dry_run: dry_run)
      when 'proxmox-iso'
        build_proxmox_iso(resolved, dry_run: dry_run)
      when 'aws'
        # Check if using direct EBS builder or qcow2 import
        if resolved['builder'] == 'aws-ebs'
          build_aws_ebs(resolved, dry_run: dry_run)
        else
          # qcow2 import path
          qcow2_path = ensure_qcow2(resolved, dry_run: dry_run, no_cache: no_cache)
          return false unless qcow2_path
          AwsConverter.new(qcow2_path, resolved).convert(dry_run: dry_run)
        end
      else
        # qcow2-based targets
        qcow2_path = ensure_qcow2(resolved, dry_run: dry_run, no_cache: no_cache)
        return false unless qcow2_path

        case target
        when 'qcow2'
          puts "\nqcow2 image ready: #{qcow2_path}"
          true
        when 'proxmox-clone'
          ProxmoxCloneConverter.new(qcow2_path, resolved).convert(dry_run: dry_run)
        when 'aws-import'
          AwsConverter.new(qcow2_path, resolved).convert(dry_run: dry_run)
        when 'utm'
          UtmConverter.new(qcow2_path, resolved).convert(dry_run: dry_run)
        else
          puts "Error: Unknown target '#{target}'"
          false
        end
      end
    end

    def build_pattern(pattern, dry_run: false, no_cache: false)
      builds = @resolver.build_config.matching_builds(pattern)

      if builds.empty?
        puts "No builds matching '#{pattern}'"
        return false
      end

      puts "Building #{builds.size} target(s): #{builds.join(', ')}\n\n"

      results = {}
      builds.each do |build_name|
        puts "=" * 60
        results[build_name] = build(build_name, dry_run: dry_run, no_cache: no_cache)
        puts
      end

      # Summary
      puts "=" * 60
      puts "Build Summary:"
      results.each do |name, success|
        status = success ? "\e[32mOK\e[0m" : "\e[31mFAILED\e[0m"
        puts "  #{name}: #{status}"
      end

      results.values.all?
    end

    def list_builds
      @resolver.build_config.build_names
    end

    def list_targets
      @resolver.target_config.target_names
    end

    def show_build(build_name)
      resolved = @resolver.resolve(build_name)

      unless resolved
        puts "Error: Build '#{build_name}' not found"
        return false
      end

      puts "Build: #{build_name}"
      puts
      puts "References:"
      puts "  ISO:     #{resolved['_iso_key'] || 'N/A'}"
      puts "  Profile: #{resolved['_profile_name']}"
      puts "  Target:  #{resolved['_target_name']}"
      puts

      cache_key = @resolver.compute_image_cache_key(resolved)
      cached = @cache.image_exists?(cache_key)

      puts "Cache:"
      puts "  Key:    #{cache_key}"
      puts "  Status: #{cached ? 'cached' : 'not built'}"
      puts "  Path:   #{@cache.image_path(cache_key)}" if cached
      puts

      puts "Resolved Configuration:"
      resolved.reject { |k, _| k.start_with?('_') }.each do |key, value|
        puts "  #{key}: #{value}"
      end

      true
    end

    private

    def ensure_qcow2(resolved, dry_run: false, no_cache: false)
      cache_key = @resolver.compute_image_cache_key(resolved)
      cached_path = @cache.image_path(cache_key)
      build_name = resolved['_build_name']

      if !no_cache && cached_path.exist?
        puts "Using cached qcow2: #{cached_path}"
        return cached_path
      end

      puts "Building qcow2 image (cache key: #{cache_key})..."

      builder = QemuBuilder.new(resolved, cache: @cache)
      success = builder.build(output_path: cached_path, dry_run: dry_run)

      return nil unless success
      return cached_path if dry_run

      # Packer outputs to images/<build_name>/<build_name>
      # We need to move it to images/<cache_key>.qcow2
      packer_output_dir = File.join(File.dirname(cached_path.to_s), build_name)
      packer_output_file = File.join(packer_output_dir, build_name)

      if File.exist?(packer_output_file)
        FileUtils.mv(packer_output_file, cached_path.to_s)
        FileUtils.rm_rf(packer_output_dir)
        puts "Moved qcow2 to cache: #{cached_path}"
      end

      if cached_path.exist?
        # Save manifest
        @cache.save_manifest(build_name, {
          'cache_key' => cache_key,
          'image_path' => cached_path.to_s,
          'built_at' => Time.now.iso8601,
          'iso' => resolved['_iso_key'],
          'profile' => resolved['_profile_name']
        })
        cached_path
      else
        puts "Error: Build completed but qcow2 not found at #{cached_path}"
        puts "  Checked packer output: #{packer_output_file}"
        nil
      end
    end

    def build_docker(resolved, dry_run: false)
      DockerBuilder.new(resolved, cache: @cache).build(dry_run: dry_run)
    end

    def build_aws_ebs(resolved, dry_run: false)
      AwsEbsBuilder.new(resolved, cache: @cache).build(dry_run: dry_run)
    end

    def build_proxmox_iso(resolved, dry_run: false)
      # Direct Packer build on Proxmox - would use proxmox-iso builder
      # For now, placeholder
      puts "proxmox-iso target not yet implemented"
      puts "Use proxmox-clone to upload a locally-built qcow2"
      false
    end
  end

  # CLI interface
  class CLI < Thor
    def self.exit_on_failure? = true
    remove_command :tree

    desc 'build [PATTERN]', 'Build image(s) matching pattern'
    option :all, type: :boolean, aliases: '-a', desc: 'Build all defined builds'
    option :dry_run, type: :boolean, aliases: '-n', desc: 'Show what would be done'
    option :no_cache, type: :boolean, desc: 'Ignore cached qcow2 images'
    def build(pattern = nil)
      if options[:all]
        manager.build_pattern('*', dry_run: options[:dry_run], no_cache: options[:no_cache])
      elsif pattern
        if manager.list_builds.include?(pattern)
          manager.build(pattern, dry_run: options[:dry_run], no_cache: options[:no_cache])
        else
          manager.build_pattern(pattern, dry_run: options[:dry_run], no_cache: options[:no_cache])
        end
      else
        puts "Usage: pim packer build <pattern>"
        puts "       pim packer build --all"
        puts
        puts "Available builds:"
        manager.list_builds.each { |b| puts "  #{b}" }
      end
    end

    desc 'list', 'List available builds'
    option :targets, type: :boolean, aliases: '-t', desc: 'List targets instead of builds'
    def list
      if options[:targets]
        puts "Available targets:"
        manager.list_targets.each { |t| puts "  #{t}" }
      else
        builds = manager.list_builds
        if builds.empty?
          puts "No builds defined. Create builds in ~/.config/pim/builds.d/"
        else
          puts "Available builds:"
          builds.each { |b| puts "  #{b}" }
        end
      end
    end

    desc 'show BUILD', 'Show resolved configuration for a build'
    def show(build_name)
      manager.show_build(build_name)
    end

    desc 'add', 'Add a new build definition interactively'
    def add
      puts "Add New Build\n\n"

      # List available options
      puts "Available ISOs:"
      resolver = manager.resolver
      resolver.iso_config.isos.keys.sort.each { |k| puts "  #{k}" }
      puts

      print "Build name: "
      name = $stdin.gets.chomp
      return puts("Error: Name required") if name.empty?

      print "ISO key: "
      iso = $stdin.gets.chomp

      puts "\nAvailable profiles:"
      resolver.profile_config.profile_names.each { |p| puts "  #{p}" }
      print "Profile [default]: "
      profile = $stdin.gets.chomp
      profile = 'default' if profile.empty?

      puts "\nAvailable targets:"
      resolver.target_config.target_names.each { |t| puts "  #{t}" }
      print "Target: "
      target = $stdin.gets.chomp
      return puts("Error: Target required") if target.empty?

      build_data = {
        'iso' => iso.empty? ? nil : iso,
        'profile' => profile,
        'target' => target
      }.compact

      puts "\nCreating build: #{name}"
      build_data.each { |k, v| puts "  #{k}: #{v}" }

      resolver.build_config.save_build(name, build_data)
      puts "\nOK Build saved to builds.d/#{name}.yml"
    end

    desc 'cache', 'Manage build cache'
    option :clear, type: :string, desc: 'Clear cache for specific build'
    option :clear_all, type: :boolean, desc: 'Clear entire cache'
    def cache
      if options[:clear_all]
        print "Clear entire build cache? (y/N) "
        return unless $stdin.gets.chomp.downcase == 'y'
        manager.cache.clear_all
        puts "Cache cleared"
      elsif options[:clear]
        manager.cache.clear(options[:clear])
        puts "Cleared cache for #{options[:clear]}"
      else
        puts "Cache directory: #{BuildCache::CACHE_DIR}"
        puts "Images directory: #{BuildCache::IMAGES_DIR}"

        if Dir.exist?(BuildCache::IMAGES_DIR)
          images = Dir.glob(File.join(BuildCache::IMAGES_DIR, '*.qcow2'))
          if images.any?
            puts "\nCached images:"
            images.each do |img|
              size = File.size(img)
              puts "  #{File.basename(img)} (#{format_bytes(size)})"
            end
          else
            puts "\nNo cached images"
          end
        end
      end
    end

    private

    def manager
      @manager ||= Manager.new
    end

    def format_bytes(bytes)
      units = ['B', 'KB', 'MB', 'GB', 'TB']
      return '0 B' if bytes == 0

      exp = (Math.log(bytes) / Math.log(1024)).floor
      exp = [exp, units.size - 1].min

      format('%.2f %s', bytes.to_f / (1024**exp), units[exp])
    end
  end
end
