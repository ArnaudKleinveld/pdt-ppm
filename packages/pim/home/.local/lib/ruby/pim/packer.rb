# frozen_string_literal: true

require 'yaml'
require 'pathname'
require 'fileutils'
require 'erb'
require 'thor'
require 'json'
require 'open3'

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

  # Configuration loader for pim packer
  class Config
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')
    GLOBAL_TEMPLATES_DIR = File.join(GLOBAL_CONFIG_DIR, 'templates', 'packer')

    BUILDERS_D = File.join(GLOBAL_CONFIG_DIR, 'builders.d')
    DISTROS_D = File.join(GLOBAL_CONFIG_DIR, 'distros.d')
    BUILDS_D = File.join(GLOBAL_CONFIG_DIR, 'builds.d')
    PROVISIONERS_D = File.join(GLOBAL_CONFIG_DIR, 'provisioners.d')

    attr_reader :runtime_config, :project_dir

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @runtime_config = load_runtime_config
      @builders = nil
      @distros = nil
      @builds = nil
      @provisioners = nil
    end

    def packer_config
      @runtime_config['packer'] || {}
    end

    def builds_dir
      packer_config['builds_dir'] || '.builds'
    end

    def default_plugins
      packer_config['plugins'] || {}
    end

    def default_build_vars
      packer_config['build_vars'] || {}
    end

    # Load builders from builders.d/*.yml
    def builders
      @builders ||= load_from_d(BUILDERS_D, 'builders.d')
    end

    # Load distros from distros.d/*.yml
    def distros
      @distros ||= load_from_d(DISTROS_D, 'distros.d')
    end

    # Load builds from builds.d/*.yml
    def builds
      @builds ||= load_from_d(BUILDS_D, 'builds.d')
    end

    # Load provisioners from provisioners.d/*.yml
    def provisioners
      @provisioners ||= load_from_d(PROVISIONERS_D, 'provisioners.d')
    end

    def builder(name)
      builders[name] || {}
    end

    def distro(name)
      distros[name] || {}
    end

    def build(name)
      builds[name] || {}
    end

    def provisioner(name)
      provisioners[name] || {}
    end

    def builder_names
      builders.keys.sort
    end

    def distro_names
      distros.keys.sort
    end

    def build_names
      builds.keys.sort
    end

    def provisioner_names
      provisioners.keys.sort
    end

    # Find template file - project first, then global
    def find_template(subpath)
      # 1. Project directory
      project_path = File.join(@project_dir, 'templates', 'packer', subpath)
      return project_path if File.exist?(project_path)

      # 2. Global config directory
      global_path = File.join(GLOBAL_TEMPLATES_DIR, subpath)
      return global_path if File.exist?(global_path)

      nil
    end

    # Find HCL file for builder/distro
    def find_hcl(type, name, filename)
      base_dir = case type
                 when :builder then BUILDERS_D
                 when :distro then DISTROS_D
                 else raise "Unknown type: #{type}"
                 end

      # Check in the .d directory with name prefix
      hcl_path = File.join(base_dir, name.tr('/', '-'), filename)
      return hcl_path if File.exist?(hcl_path)

      # Project directory
      project_path = File.join(@project_dir, type.to_s + 's', name, filename)
      return project_path if File.exist?(project_path)

      nil
    end

    private

    def load_runtime_config
      config = {}

      # Global pim.yml
      global_file = File.join(GLOBAL_CONFIG_DIR, 'pim.yml')
      config = DeepMerge.merge(config, load_yaml(global_file))

      # Project pim.yml
      project_file = File.join(@project_dir, 'pim.yml')
      config = DeepMerge.merge(config, load_yaml(project_file))

      # Project packer.yml (convenience)
      packer_file = File.join(@project_dir, 'packer.yml')
      if File.exist?(packer_file)
        packer_config = load_yaml(packer_file)
        config['packer'] = DeepMerge.merge(config['packer'] || {}, packer_config)
      end

      config
    end

    def load_from_d(global_dir, project_subdir)
      items = {}

      # Load from global .d directory
      if Dir.exist?(global_dir)
        Dir.glob(File.join(global_dir, '*.yml')).sort.each do |file|
          items = DeepMerge.merge(items, load_yaml(file))
        end
      end

      # Load from project directory
      project_d = File.join(@project_dir, project_subdir)
      if Dir.exist?(project_d)
        Dir.glob(File.join(project_d, '*.yml')).sort.each do |file|
          items = DeepMerge.merge(items, load_yaml(file))
        end
      end

      items
    end

    def load_yaml(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse #{path}: #{e.message}"
      {}
    end
  end

  # Builder model
  class Builder
    attr_reader :name, :data

    def initialize(name, data)
      @name = name
      @data = data || {}
    end

    def type
      @data['type'] || @name
    end

    def plugins
      @data['plugins'] || {}
    end

    def build_vars
      @data['build_vars'] || {}
    end

    def hcl_files
      @data['hcl_files'] || %w[variables.pkr.hcl locals.pkr.hcl sources.pkr.hcl]
    end

    def to_h
      @data
    end
  end

  # Distro model
  class Distro
    attr_reader :name, :data

    def initialize(name, data)
      @name = name
      @data = data || {}
    end

    def slug
      @data['slug'] || @name.tr('/', '-')
    end

    def iso_key
      @data['iso_key']
    end

    def build_vars
      @data['build_vars'] || {}
    end

    def boot_command
      @data.dig('boot', 'command')
    end

    def boot_wait
      @data.dig('boot', 'wait') || '6s'
    end

    def preseed_template
      @data.dig('preseed', 'template')
    end

    def hcl_files
      @data['hcl_files'] || %w[variables.pkr.hcl locals.pkr.hcl sources.pkr.hcl provisioners.pkr.hcl]
    end

    def provisioners
      @data['provisioners'] || []
    end

    def to_h
      @data
    end
  end

  # Provisioner model
  class Provisioner
    attr_reader :name, :data

    def initialize(name, data)
      @name = name
      @data = data || {}
    end

    def type
      @data['type'] || 'shell'
    end

    def config
      @data['config'] || {}
    end

    def to_h
      @data
    end
  end

  # Build model - combines distros, builders, and provisioners
  class Build
    attr_reader :name, :data, :config

    def initialize(name, data, config)
      @name = name
      @data = data || {}
      @config = config
    end

    def build_vars
      @data['build_vars'] || {}
    end

    def distro_names
      (@data['distros'] || {}).keys
    end

    def builder_names
      (@data['builders'] || {}).keys
    end

    def provisioner_names
      @data['provisioners'] || []
    end

    def distro_overrides(distro_name)
      @data.dig('distros', distro_name) || {}
    end

    def builder_overrides(builder_name)
      @data.dig('builders', builder_name) || {}
    end

    # Resolve merged build_vars for a specific distro/builder combination
    def resolve_vars(distro_name, builder_name, cli_vars = {})
      vars = {}

      # 1. Global packer.yml build_vars (lowest precedence)
      vars = DeepMerge.merge(vars, @config.default_build_vars)

      # 2. Builder build_vars
      builder = Builder.new(builder_name, @config.builder(builder_name))
      vars = DeepMerge.merge(vars, builder.build_vars)

      # 3. Distro build_vars
      distro = Distro.new(distro_name, @config.distro(distro_name))
      vars = DeepMerge.merge(vars, distro.build_vars)

      # 4. Build build_vars
      vars = DeepMerge.merge(vars, build_vars)

      # 5. Build-level distro overrides
      vars = DeepMerge.merge(vars, distro_overrides(distro_name).fetch('build_vars', {}))

      # 6. Build-level builder overrides
      vars = DeepMerge.merge(vars, builder_overrides(builder_name).fetch('build_vars', {}))

      # 7. CLI --var overrides (highest precedence)
      vars = DeepMerge.merge(vars, cli_vars)

      vars
    end

    # Collect all plugins needed for this build
    def resolve_plugins(builder_name)
      plugins = {}

      # Global plugins
      plugins = DeepMerge.merge(plugins, @config.default_plugins)

      # Builder plugins
      builder = Builder.new(builder_name, @config.builder(builder_name))
      plugins = DeepMerge.merge(plugins, builder.plugins)

      plugins
    end

    def to_h
      @data
    end
  end

  # HCL Renderer - generates HCL files from ERB templates
  class HclRenderer
    def initialize(config)
      @config = config
    end

    # Render an ERB template with the given bindings
    def render_template(template_path, bindings)
      return nil unless template_path && File.exist?(template_path)

      template_content = File.read(template_path)
      template = ERB.new(template_content, trim_mode: '-')
      template.result_with_hash(bindings)
    end

    # Render the main build.pkr.hcl file
    def render_build_hcl(build:, distro:, builder:, plugins:, sources_content:, provisioners_content:)
      bindings = {
        template_run_date: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        plugins: plugins,
        sources_content: sources_content,
        provisioners_content: provisioners_content,
        build: build,
        distro: distro,
        builder: builder
      }

      template_path = @config.find_template('build.pkr.hcl.erb')
      render_template(template_path, bindings)
    end

    # Render the pkrvars.hcl file with variable values
    def render_pkrvars_hcl(build_vars)
      bindings = {
        template_run_date: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        build_vars: build_vars
      }

      template_path = @config.find_template('build.pkrvars.hcl.erb')
      render_template(template_path, bindings)
    end

    # Format a value for HCL output
    def self.format_hcl_value(value)
      case value
      when true, false
        value.to_s
      when Integer, Float
        value.to_s
      when Array
        "[#{value.map { |v| format_hcl_value(v) }.join(', ')}]"
      when Hash
        pairs = value.map { |k, v| "#{k} = #{format_hcl_value(v)}" }
        "{\n  #{pairs.join("\n  ")}\n}"
      when nil
        'null'
      else
        # String - escape and quote
        "\"#{value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}\""
      end
    end
  end

  # Executor - runs packer commands
  class Executor
    def initialize(config)
      @config = config
    end

    def packer_init(build_dir)
      run_packer('init', build_dir)
    end

    def packer_validate(build_dir)
      run_packer('validate', build_dir)
    end

    def packer_build(build_dir, var_file: nil)
      args = []
      args += ['-var-file', var_file] if var_file
      run_packer('build', build_dir, args)
    end

    private

    def run_packer(command, build_dir, extra_args = [])
      cmd = ['packer', command] + extra_args + ['.']
      puts "Running: #{cmd.join(' ')}"
      puts "  in: #{build_dir}"

      Dir.chdir(build_dir) do
        system(*cmd)
      end
    end
  end

  # Core packer management logic
  class Manager
    attr_reader :config

    def initialize(config: nil, project_dir: Dir.pwd)
      @config = config || Config.new(project_dir: project_dir)
      @renderer = HclRenderer.new(@config)
      @executor = Executor.new(@config)
    end

    # List available items
    def list(type)
      items = case type
              when 'builds', 'build' then @config.build_names
              when 'builders', 'builder' then @config.builder_names
              when 'distros', 'distro' then @config.distro_names
              when 'provisioners', 'provisioner' then @config.provisioner_names
              else
                puts "Unknown type: #{type}"
                puts "Available types: builds, builders, distros, provisioners"
                return
              end

      if items.empty?
        puts "No #{type} configured."
      else
        items.each { |name| puts name }
      end
    end

    # Show merged configuration for a build
    def show(build_name, distro: nil, builder: nil)
      build_data = @config.build(build_name)
      if build_data.empty?
        puts "Error: Build '#{build_name}' not found"
        puts "Available builds: #{@config.build_names.join(', ')}"
        return false
      end

      build = Build.new(build_name, build_data, @config)

      puts "Build: #{build_name}"
      puts

      # Show distros
      distros = distro ? [distro] : build.distro_names
      puts "Distros:"
      distros.each { |d| puts "  - #{d}" }
      puts

      # Show builders
      builders = builder ? [builder] : build.builder_names
      puts "Builders:"
      builders.each { |b| puts "  - #{b}" }
      puts

      # Show provisioners
      unless build.provisioner_names.empty?
        puts "Provisioners:"
        build.provisioner_names.each { |p| puts "  - #{p}" }
        puts
      end

      # Show merged vars for first distro/builder combination
      d = distros.first
      b = builders.first
      puts "Merged build_vars (#{d} + #{b}):"
      vars = build.resolve_vars(d, b)
      vars.sort.each do |key, value|
        puts "  #{key}: #{value.inspect}"
      end

      true
    end

    # Generate HCL files for a build
    def generate(build_name, distro: nil, builder: nil, output: nil, vars: {}, dry_run: false)
      build_data = @config.build(build_name)
      if build_data.empty?
        puts "Error: Build '#{build_name}' not found"
        return false
      end

      build = Build.new(build_name, build_data, @config)

      # Determine distros and builders to process
      distros = distro ? [distro] : build.distro_names
      builders = builder ? [builder] : build.builder_names

      if distros.empty?
        puts "Error: No distros configured for build '#{build_name}'"
        return false
      end

      if builders.empty?
        puts "Error: No builders configured for build '#{build_name}'"
        return false
      end

      output_base = output || File.join(@config.project_dir, @config.builds_dir, build_name)

      distros.each do |distro_name|
        distro_obj = Distro.new(distro_name, @config.distro(distro_name))

        builders.each do |builder_name|
          builder_obj = Builder.new(builder_name, @config.builder(builder_name))

          build_dir = File.join(output_base, distro_obj.slug)
          puts "Generating: #{build_dir}"

          if dry_run
            puts "  (dry-run, skipping)"
            next
          end

          generate_build(build, distro_obj, builder_obj, build_dir, vars)
        end
      end

      true
    end

    # Generate + validate
    def validate(build_name, **options)
      return false unless generate(build_name, **options)

      build_data = @config.build(build_name)
      build = Build.new(build_name, build_data, @config)
      output_base = options[:output] || File.join(@config.project_dir, @config.builds_dir, build_name)

      distros = options[:distro] ? [options[:distro]] : build.distro_names
      builders = options[:builder] ? [options[:builder]] : build.builder_names

      distros.each do |distro_name|
        distro_obj = Distro.new(distro_name, @config.distro(distro_name))
        builders.each do |_builder_name|
          build_dir = File.join(output_base, distro_obj.slug)
          @executor.packer_validate(build_dir)
        end
      end
    end

    # Generate + init
    def init(build_name, **options)
      return false unless generate(build_name, **options)

      build_data = @config.build(build_name)
      build = Build.new(build_name, build_data, @config)
      output_base = options[:output] || File.join(@config.project_dir, @config.builds_dir, build_name)

      distros = options[:distro] ? [options[:distro]] : build.distro_names
      builders = options[:builder] ? [options[:builder]] : build.builder_names

      distros.each do |distro_name|
        distro_obj = Distro.new(distro_name, @config.distro(distro_name))
        builders.each do |_builder_name|
          build_dir = File.join(output_base, distro_obj.slug)
          @executor.packer_init(build_dir)
        end
      end
    end

    # Generate + build
    def build(build_name, **options)
      return false unless generate(build_name, **options)

      build_data = @config.build(build_name)
      build_obj = Build.new(build_name, build_data, @config)
      output_base = options[:output] || File.join(@config.project_dir, @config.builds_dir, build_name)

      distros = options[:distro] ? [options[:distro]] : build_obj.distro_names
      builders = options[:builder] ? [options[:builder]] : build_obj.builder_names

      distros.each do |distro_name|
        distro_obj = Distro.new(distro_name, @config.distro(distro_name))
        builders.each do |_builder_name|
          build_dir = File.join(output_base, distro_obj.slug)
          var_file = File.join(build_dir, '_build.pkrvars.hcl')
          @executor.packer_build(build_dir, var_file: var_file)
        end
      end
    end

    # Show packer configuration
    def show_config
      puts "Packer Configuration"
      puts
      puts "builds_dir: #{@config.builds_dir}"
      puts "templates_dir: #{Config::GLOBAL_TEMPLATES_DIR}"
      puts
      puts "Directories:"
      puts "  builders.d: #{Config::BUILDERS_D}"
      puts "  distros.d: #{Config::DISTROS_D}"
      puts "  builds.d: #{Config::BUILDS_D}"
      puts "  provisioners.d: #{Config::PROVISIONERS_D}"
      puts
      puts "Counts:"
      puts "  builders: #{@config.builder_names.size}"
      puts "  distros: #{@config.distro_names.size}"
      puts "  builds: #{@config.build_names.size}"
      puts "  provisioners: #{@config.provisioner_names.size}"
    end

    private

    def generate_build(build, distro, builder, build_dir, cli_vars)
      # Create build directory
      FileUtils.rm_rf(build_dir)
      FileUtils.mkdir_p(build_dir)

      # Create http directory for preseed
      http_dir = File.join(build_dir, 'http')
      FileUtils.mkdir_p(http_dir)

      # Resolve merged variables
      build_vars = build.resolve_vars(distro.name, builder.name, cli_vars)
      plugins = build.resolve_plugins(builder.name)

      # Collect HCL content from builder
      builder_content = collect_hcl_content(:builder, builder)

      # Collect HCL content from distro
      distro_content = collect_hcl_content(:distro, distro)

      # Combine content
      variables_content = [builder_content[:variables], distro_content[:variables]].compact.join("\n\n")
      locals_content = [builder_content[:locals], distro_content[:locals]].compact.join("\n\n")
      sources_content = [builder_content[:sources], distro_content[:sources]].compact.join("\n\n")
      provisioners_content = distro_content[:provisioners] || ''

      # Write combined HCL files
      write_if_present(File.join(build_dir, 'variables.pkr.hcl'), variables_content)
      write_if_present(File.join(build_dir, 'locals.pkr.hcl'), locals_content)
      write_if_present(File.join(build_dir, 'sources.pkr.hcl'), sources_content)

      # Generate build.pkr.hcl from template
      build_hcl = @renderer.render_build_hcl(
        build: build,
        distro: distro,
        builder: builder,
        plugins: plugins,
        sources_content: sources_content,
        provisioners_content: provisioners_content
      )
      if build_hcl
        File.write(File.join(build_dir, '_build.pkr.hcl'), build_hcl)
      else
        # Fallback: generate minimal build.pkr.hcl
        generate_minimal_build_hcl(build_dir, plugins, builder, provisioners_content)
      end

      # Generate pkrvars.hcl from template
      pkrvars_hcl = @renderer.render_pkrvars_hcl(build_vars)
      if pkrvars_hcl
        File.write(File.join(build_dir, '_build.pkrvars.hcl'), pkrvars_hcl)
      else
        # Fallback: generate minimal pkrvars
        generate_minimal_pkrvars(build_dir, build_vars)
      end

      # Copy preseed template if exists
      copy_preseed_template(distro, build_dir, http_dir)

      puts "  Generated #{build_dir}"
    end

    def collect_hcl_content(type, obj)
      content = { variables: nil, locals: nil, sources: nil, provisioners: nil }

      base_dir = case type
                 when :builder then Config::BUILDERS_D
                 when :distro then Config::DISTROS_D
                 end

      # Look for HCL files in the .d subdirectory
      hcl_dir = File.join(base_dir, obj.name.tr('/', '-'))

      %w[variables locals sources provisioners].each do |file_type|
        hcl_file = File.join(hcl_dir, "#{file_type}.pkr.hcl")
        content[file_type.to_sym] = File.read(hcl_file) if File.exist?(hcl_file)
      end

      content
    end

    def write_if_present(path, content)
      return if content.nil? || content.strip.empty?
      File.write(path, content)
    end

    def generate_minimal_build_hcl(build_dir, plugins, builder, provisioners_content)
      content = <<~HCL
        # Generated by pim packer

        packer {
          required_plugins {
      HCL

      plugins.each do |name, config|
        content += "    #{name} = {\n"
        config.each do |key, value|
          content += "      #{key.ljust(7)} = \"#{value}\"\n"
        end
        content += "    }\n"
      end

      content += <<~HCL
          }
        }

        build {
          sources = [
            "source.#{builder.type}.generic"
          ]

        #{provisioners_content}
        }
      HCL

      File.write(File.join(build_dir, '_build.pkr.hcl'), content)
    end

    def generate_minimal_pkrvars(build_dir, build_vars)
      content = "# Generated by pim packer\n\n"

      build_vars.sort.each do |key, value|
        content += "#{key.ljust(40)} = #{HclRenderer.format_hcl_value(value)}\n"
      end

      File.write(File.join(build_dir, '_build.pkrvars.hcl'), content)
    end

    def copy_preseed_template(distro, build_dir, http_dir)
      template_name = distro.preseed_template
      return unless template_name

      # Look for preseed template in distro's hcl directory
      distro_dir = File.join(Config::DISTROS_D, distro.name.tr('/', '-'))
      template_path = File.join(distro_dir, 'templates', template_name)

      return unless File.exist?(template_path)

      # Copy to http directory with .pkrtpl extension for Packer templatefile()
      dest_name = template_name.sub(/\.erb$/, '')
      FileUtils.cp(template_path, File.join(http_dir, dest_name))
      puts "  Copied preseed template: #{dest_name}"
    end
  end

  # CLI interface for pim packer
  class CLI < Thor
    def self.exit_on_failure? = true
    remove_command :tree

    desc 'list TYPE', 'List available items (builds, builders, distros, provisioners)'
    def list(type = 'builds')
      manager.list(type)
    end
    map 'ls' => :list

    desc 'show BUILD', 'Show merged configuration for a build'
    option :distro, type: :string, aliases: '-d', desc: 'Specific distro'
    option :builder, type: :string, aliases: '-b', desc: 'Specific builder'
    def show(build_name)
      manager.show(build_name, distro: options[:distro], builder: options[:builder])
    end

    desc 'generate BUILD', 'Generate HCL files for a build'
    option :distro, type: :string, aliases: '-d', desc: 'Specific distro'
    option :builder, type: :string, aliases: '-b', desc: 'Specific builder'
    option :output, type: :string, aliases: '-o', desc: 'Output directory'
    option :var, type: :array, aliases: '-v', default: [], desc: 'Override variables (key=value)'
    option :dry_run, type: :boolean, aliases: '-n', desc: 'Show what would happen'
    def generate(build_name)
      vars = parse_vars(options[:var])
      manager.generate(
        build_name,
        distro: options[:distro],
        builder: options[:builder],
        output: options[:output],
        vars: vars,
        dry_run: options[:dry_run]
      )
    end

    desc 'validate BUILD', 'Generate HCL and run packer validate'
    option :distro, type: :string, aliases: '-d', desc: 'Specific distro'
    option :builder, type: :string, aliases: '-b', desc: 'Specific builder'
    option :output, type: :string, aliases: '-o', desc: 'Output directory'
    option :var, type: :array, aliases: '-v', default: [], desc: 'Override variables (key=value)'
    def validate(build_name)
      vars = parse_vars(options[:var])
      manager.validate(
        build_name,
        distro: options[:distro],
        builder: options[:builder],
        output: options[:output],
        vars: vars
      )
    end

    desc 'init BUILD', 'Generate HCL and run packer init'
    option :distro, type: :string, aliases: '-d', desc: 'Specific distro'
    option :builder, type: :string, aliases: '-b', desc: 'Specific builder'
    option :output, type: :string, aliases: '-o', desc: 'Output directory'
    option :var, type: :array, aliases: '-v', default: [], desc: 'Override variables (key=value)'
    def init(build_name)
      vars = parse_vars(options[:var])
      manager.init(
        build_name,
        distro: options[:distro],
        builder: options[:builder],
        output: options[:output],
        vars: vars
      )
    end

    desc 'build BUILD', 'Generate HCL and run packer build'
    option :distro, type: :string, aliases: '-d', desc: 'Specific distro'
    option :builder, type: :string, aliases: '-b', desc: 'Specific builder'
    option :output, type: :string, aliases: '-o', desc: 'Output directory'
    option :var, type: :array, aliases: '-v', default: [], desc: 'Override variables (key=value)'
    def build(build_name)
      vars = parse_vars(options[:var])
      manager.build(
        build_name,
        distro: options[:distro],
        builder: options[:builder],
        output: options[:output],
        vars: vars
      )
    end

    desc 'config', 'Show packer configuration'
    def config
      manager.show_config
    end

    private

    def manager
      @manager ||= Manager.new
    end

    def parse_vars(var_array)
      vars = {}
      var_array.each do |v|
        key, value = v.split('=', 2)
        vars[key] = value if key && value
      end
      vars
    end
  end
end
