# frozen_string_literal: true

require 'yaml'
require 'pathname'
require 'digest'
require 'net/http'
require 'uri'
require 'openssl'
require 'fileutils'
require 'thor'

module PimIso
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

  # Configuration loader for pim-iso
  class Config
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    XDG_CACHE_HOME = ENV.fetch('XDG_CACHE_HOME', File.expand_path('~/.cache'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')
    GLOBAL_CONFIG_D = File.join(GLOBAL_CONFIG_DIR, 'isos.d')

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @runtime_config = load_runtime_config
      @isos = load_isos
    end

    def isos
      @isos
    end

    def iso_dir
      dir_path = @runtime_config.dig('iso', 'iso_dir')
      return default_iso_dir unless dir_path

      expanded = dir_path.gsub('$HOME', Dir.home)
                         .gsub('$XDG_CACHE_HOME', XDG_CACHE_HOME)
      Pathname.new(File.expand_path(expanded))
    end

    def save_iso(key, iso_data)
      FileUtils.mkdir_p(GLOBAL_CONFIG_D)
      File.write(File.join(GLOBAL_CONFIG_D, "#{key}.yml"), YAML.dump({ key => iso_data }))
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

      config
    end

    def load_isos
      isos = {}

      # Load from isos.d/*.yml (each file contains ISO entries directly)
      load_isos_d(GLOBAL_CONFIG_D).each do |fragment|
        isos = DeepMerge.merge(isos, fragment)
      end

      # Load from project isos.yml (entries directly, no wrapper)
      project_file = File.join(@project_dir, 'isos.yml')
      isos = DeepMerge.merge(isos, load_yaml(project_file))

      isos
    end

    def load_yaml(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse #{path}: #{e.message}"
      {}
    end

    def load_isos_d(dir)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, '*.yml')).sort.map do |file|
        load_yaml(file)
      end
    end

    def default_iso_dir
      Pathname.new(File.join(XDG_CACHE_HOME, 'pim', 'isos'))
    end
  end

  # Core ISO management logic
  class Manager
    def initialize(config: nil, project_dir: Dir.pwd)
      @config_obj = config || Config.new(project_dir: project_dir)
      ensure_iso_dir_exists
    end

    def isos
      @config_obj.isos
    end

    def iso_dir
      @config_obj.iso_dir
    end

    # Find an ISO by architecture
    # Returns [key, data] or nil if not found
    def find_by_arch(arch)
      normalized = normalize_arch(arch)

      isos.each do |key, data|
        iso_arch = normalize_arch(data['architecture'])
        return [key, data] if iso_arch == normalized
      end

      nil
    end

    # Get ISO path for a given key
    def iso_path(key)
      iso = isos[key]
      return nil unless iso

      filename = iso['filename'] || "#{key}.iso"
      iso_dir / filename
    end

    def list(long: false)
      if isos.empty?
        puts 'No ISOs in catalog. Use "pim-iso add" to add some.'
        return
      end

      if long
        list_long
      else
        isos.keys.sort.each { |key| puts key }
      end
    end

    def download(key, force: false)
      unless isos[key]
        puts "Error: ISO '#{key}' not found in catalog"
        return false
      end

      iso = isos[key]
      filename = iso['filename'] || "#{key}.iso"
      filepath = iso_dir / filename

      if filepath.exist? && !force
        print "File exists. Re-download? (y/N) "
        response = $stdin.gets.chomp
        return false unless response.downcase == 'y'
      end

      puts "Downloading #{filename}..."
      download_file(iso['url'], filepath)
      puts

      puts 'Verifying checksum...'
      verify(key, silent: false)
    end

    def download_all
      missing = isos.select do |key, iso|
        filename = iso['filename'] || "#{key}.iso"
        !file_exists?(filename)
      end

      if missing.empty?
        puts 'All ISOs are already downloaded.'
        return
      end

      puts "Downloading missing ISOs...\n\n"

      success_count = 0
      missing.each.with_index(1) do |(key, iso), idx|
        puts "[#{idx}/#{missing.size}] Downloading #{key}..."
        filename = iso['filename'] || "#{key}.iso"
        filepath = iso_dir / filename

        download_file(iso['url'], filepath)

        if verify(key, silent: true)
          puts "OK Downloaded and verified\n\n"
          success_count += 1
        else
          puts "FAIL Checksum verification failed\n\n"
        end
      end

      puts "Summary: #{success_count} ISOs downloaded successfully"
    end

    def verify(key, silent: false)
      unless isos[key]
        puts "Error: ISO '#{key}' not found in catalog" unless silent
        return false
      end

      iso = isos[key]
      filename = iso['filename'] || "#{key}.iso"
      filepath = iso_dir / filename

      unless filepath.exist?
        puts "Error: File '#{filename}' not found in #{iso_dir}" unless silent
        return false
      end

      puts "Verifying #{filename}..." unless silent

      actual_checksum = calculate_checksum(filepath)
      expected_checksum = iso['checksum'].to_s.sub('sha256:', '')

      if actual_checksum == expected_checksum
        puts "OK Checksum matches: sha256:#{actual_checksum[0..15]}..." unless silent
        true
      else
        puts "FAIL Checksum mismatch!" unless silent
        puts "  Expected: sha256:#{expected_checksum[0..15]}..." unless silent
        puts "  Got:      sha256:#{actual_checksum[0..15]}..." unless silent
        false
      end
    end

    def verify_all
      downloaded = isos.select do |key, iso|
        filename = iso['filename'] || "#{key}.iso"
        file_exists?(filename)
      end

      if downloaded.empty?
        puts 'No downloaded ISOs to verify.'
        return
      end

      puts "Verifying downloaded ISOs...\n\n"

      passed = 0
      failed = 0

      downloaded.each do |key, iso|
        filename = iso['filename'] || "#{key}.iso"
        result = verify(key, silent: true)
        status = result ? 'OK' : 'FAIL Checksum mismatch'
        puts "#{filename.ljust(35)} #{status}"

        result ? passed += 1 : failed += 1
      end

      puts
      puts "Summary: #{passed} passed, #{failed} failed"
    end

    def add
      puts "Add New ISO to Catalog\n\n"

      print 'ISO URL: '
      url = $stdin.gets.chomp

      unless url.start_with?('http://', 'https://')
        puts 'Error: URL must start with http:// or https://'
        return false
      end

      print 'Checksum (hash or URL): '
      checksum_input = $stdin.gets.chomp

      puts "\nProcessing..."

      attributes = derive_attributes(url, checksum_input)
      return false unless attributes

      key = attributes[:filename].sub(/\.iso$/, '')

      puts "\nAdding to catalog as: #{key}\n\n"
      puts "name: #{attributes[:name]}"
      puts "url: #{attributes[:url]}"
      puts "checksum: #{attributes[:checksum]}"
      puts "checksum_url: #{attributes[:checksum_url]}" if attributes[:checksum_url]
      puts "filename: #{attributes[:filename]}"
      puts "architecture: #{attributes[:architecture]}"

      iso_data = {
        'name' => attributes[:name],
        'url' => attributes[:url],
        'checksum' => attributes[:checksum],
        'checksum_url' => attributes[:checksum_url],
        'filename' => attributes[:filename],
        'architecture' => attributes[:architecture]
      }.compact

      @config_obj.save_iso(key, iso_data)

      puts "\nOK Added to catalog"
      true
    end

    private

    def list_long
      total_bytes = 0
      max_name_len = isos.keys.map(&:length).max

      isos.keys.sort.each do |key|
        iso = isos[key]
        filename = iso['filename'] || "#{key}.iso"
        filepath = iso_dir / filename

        if filepath.exist?
          size = filepath.size
          total_bytes += size
          size_str = format_bytes(size).rjust(10)
          verified = iso_verified?(key)
          status = verified ? colorize('verified', :green) : colorize('downloaded', :yellow)
          path_col = verified ? "  #{filepath}" : ''
        else
          size_str = '-'.rjust(10)
          status = colorize('missing', :red)
          path_col = ''
        end

        puts "#{key.ljust(max_name_len)}  #{size_str}  #{status}#{path_col}"
      end

      puts
      puts "Total: #{format_bytes(total_bytes)}"
    end

    def iso_verified?(key)
      iso = isos[key]
      filename = iso['filename'] || "#{key}.iso"
      filepath = iso_dir / filename

      return false unless filepath.exist?

      actual_checksum = calculate_checksum(filepath)
      expected_checksum = iso['checksum'].to_s.sub(/^sha\d+:/, '')
      actual_checksum == expected_checksum
    end

    def colorize(text, color)
      colors = { red: 31, yellow: 33, green: 32 }
      "\e[#{colors[color]}m#{text}\e[0m"
    end

    def ensure_iso_dir_exists
      iso_dir.mkpath unless iso_dir.exist?
    end

    def file_exists?(filename)
      (iso_dir / filename).exist?
    end

    def normalize_arch(arch)
      return nil unless arch

      case arch.to_s.downcase
      when 'arm64', 'aarch64' then 'arm64'
      when 'x86_64', 'amd64' then 'x86_64'
      else arch.to_s.downcase
      end
    end

    def derive_attributes(url, checksum_input)
      uri = URI.parse(url)
      filename = uri.path.split('/').last

      unless filename&.end_with?('.iso')
        puts 'Error: Filename must end with .iso'
        return nil
      end

      puts "  OK Extracted filename: #{filename}"

      name = filename.sub(/\.iso$/, '').gsub(/[-_]/, ' ').split.map(&:capitalize).join(' ')

      arch_patterns = {
        'amd64' => /amd64/i,
        'x86_64' => /x86[-_]?64/i,
        'arm64' => /arm64/i,
        'aarch64' => /aarch64/i,
        'i386' => /i386/i,
        'x86' => /\bx86\b/i,
        'armhf' => /armhf/i
      }

      architecture = 'unknown'
      arch_patterns.each do |arch, pattern|
        if filename.match?(pattern)
          architecture = arch
          break
        end
      end

      puts "  OK Detected architecture: #{architecture}"

      checksum = nil
      checksum_url = nil

      if checksum_input.start_with?('http://', 'https://')
        checksum_url = checksum_input
        puts "  OK Downloading checksum file..."
        checksum = download_checksum_file(checksum_url, filename)
        return nil unless checksum
        puts "  OK Extracted checksum: #{checksum}"
      elsif checksum_input.match?(/^[a-f0-9]{64}$/i)
        checksum = "sha256:#{checksum_input}"
      elsif checksum_input.start_with?('sha256:')
        checksum = checksum_input
      else
        puts 'Error: Checksum must be 64 hex characters or start with sha256:'
        return nil
      end

      {
        name: name,
        url: url,
        checksum: checksum,
        checksum_url: checksum_url,
        filename: filename,
        architecture: architecture
      }
    end

    def download_file(url, destination, redirect_limit = 5)
      raise 'Too many redirects' if redirect_limit == 0

      uri = URI.parse(url)

      http = Net::HTTP.new(uri.host, uri.port)
      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      http.start do
        request = Net::HTTP::Get.new(uri.request_uri)

        http.request(request) do |response|
          case response
          when Net::HTTPRedirection
            return download_file(response['location'], destination, redirect_limit - 1)
          when Net::HTTPSuccess
            total_size = response['content-length'].to_i
            downloaded = 0

            File.open(destination, 'wb') do |file|
              response.read_body do |chunk|
                file.write(chunk)
                downloaded += chunk.size

                if total_size > 0
                  percentage = (downloaded.to_f / total_size * 100).round(1)
                  print "\rProgress: #{format_bytes(downloaded)} / #{format_bytes(total_size)} (#{percentage}%)"
                else
                  print "\rDownloaded: #{format_bytes(downloaded)}"
                end
              end
            end
          else
            raise "HTTP Error: #{response.code} #{response.message}"
          end
        end
      end
    end

    def calculate_checksum(filepath)
      Digest::SHA256.file(filepath).hexdigest
    end

    def download_checksum_file(url, filename)
      uri = URI.parse(url)

      http = Net::HTTP.new(uri.host, uri.port)
      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      response = http.get(uri.request_uri)

      unless response.is_a?(Net::HTTPSuccess)
        puts 'Error: Failed to download checksum file'
        return nil
      end

      content = response.body

      content.each_line do |line|
        parts = line.strip.split(/\s+/)
        next if parts.size < 2

        hash = parts[0]
        file = parts[-1].sub(/^\*/, '')

        return "sha256:#{hash}" if file == filename
      end

      puts "Error: Could not find checksum for #{filename} in checksum file"
      nil
    end

    def format_bytes(bytes)
      units = ['B', 'KB', 'MB', 'GB', 'TB']
      return '0 B' if bytes == 0

      exp = (Math.log(bytes) / Math.log(1024)).floor
      exp = [exp, units.size - 1].min

      format('%.2f %s', bytes.to_f / (1024**exp), units[exp])
    end
  end

  # CLI interface for pim-iso
  class CLI < Thor
    def self.exit_on_failure? = true
    remove_command :tree

    desc 'list', 'List ISOs in catalog'
    option :long, type: :boolean, aliases: '-l', desc: 'Long format with size and status'
    map 'ls' => :list
    def list
      manager.list(long: options[:long])
    end

    desc 'download ISO_KEY', 'Download a specific ISO from catalog'
    option :all, type: :boolean, aliases: '-a', desc: 'Download all missing ISOs'
    def download(iso_key = nil)
      if options[:all]
        manager.download_all
      elsif iso_key
        manager.download(iso_key)
      else
        puts 'Error: Provide an ISO key or use --all flag'
        exit 1
      end
    end

    desc 'verify ISO_KEY', 'Verify checksum of a downloaded ISO'
    option :all, type: :boolean, aliases: '-a', desc: 'Verify all downloaded ISOs'
    def verify(iso_key = nil)
      if options[:all]
        manager.verify_all
      elsif iso_key
        manager.verify(iso_key)
      else
        puts 'Error: Provide an ISO key or use --all flag'
        exit 1
      end
    end

    desc 'add', 'Add a new ISO to the catalog interactively'
    def add
      manager.add
    end

    private

    def manager
      @manager ||= Manager.new
    end
  end
end
