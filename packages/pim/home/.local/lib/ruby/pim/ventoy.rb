# frozen_string_literal: true

require 'yaml'
require 'pathname'
require 'digest'
require 'open3'
require 'fileutils'
require 'thor'

module PimVentoy
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

  # Configuration loader for pim-ventoy
  class Config
    XDG_CONFIG_HOME = ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config'))
    XDG_CACHE_HOME = ENV.fetch('XDG_CACHE_HOME', File.expand_path('~/.cache'))
    GLOBAL_CONFIG_DIR = File.join(XDG_CONFIG_HOME, 'pim')

    def initialize(project_dir: Dir.pwd)
      @project_dir = project_dir
      @runtime_config = load_runtime_config
    end

    def ventoy_config
      @runtime_config['ventoy'] || {}
    end

    def version
      ventoy_config['version']
    end

    def dir
      ventoy_config['dir']
    end

    def file
      ventoy_config['file']
    end

    def checksum
      ventoy_config['checksum']
    end

    def device
      ventoy_config['device']
    end

    def ventoy_dir
      Pathname.new(File.join(XDG_CACHE_HOME, 'pim', 'ventoy', dir.to_s))
    end

    def mount_point
      Pathname.new(File.join(XDG_CACHE_HOME, 'pim', 'ventoy', 'mnt'))
    end

    def iso_dir
      Pathname.new(File.join(XDG_CACHE_HOME, 'pim', 'isos'))
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

    def load_yaml(path)
      return {} unless File.exist?(path)
      YAML.load_file(path) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse #{path}: #{e.message}"
      {}
    end
  end

  # Core Ventoy management logic
  class Manager
    def initialize(config: nil, project_dir: Dir.pwd)
      @config = config || Config.new(project_dir: project_dir)
    end

    attr_reader :config

    def verify_ventoy_install
      ventoy_script = @config.ventoy_dir / 'Ventoy2Disk.sh'

      unless ventoy_script.exist?
        puts "Error: Ventoy not installed at #{@config.ventoy_dir}"
        puts "Run 'ppm install pim' to download Ventoy binaries"
        return false
      end

      puts "Ventoy binaries found at #{@config.ventoy_dir}"
      true
    end

    def validate_device(device)
      unless File.exist?(device)
        puts "Error: Device #{device} does not exist"
        puts "\nAvailable block devices:"
        system("lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E 'disk|part'")
        return nil
      end

      unless device.start_with?('/dev/')
        puts "Error: Invalid device path: #{device}"
        puts "Device path must start with /dev/"
        return nil
      end

      # Check if it's a partition instead of whole disk
      if device =~ /\d+$/
        puts "Warning: #{device} appears to be a partition, not a whole disk"
        base_device = device.gsub(/\d+$/, '')
        print "Did you mean to use #{base_device} instead? (y/N) "
        response = $stdin.gets.chomp
        device = base_device if response.downcase == 'y'
      end

      # Get device info
      device_info = `lsblk -n -o SIZE,MODEL #{device} 2>/dev/null`.strip
      if device_info.empty?
        puts "Error: Cannot get device info for #{device}"
        return nil
      end

      puts "\nDevice: #{device}"
      puts "Info: #{device_info}"

      # Check for system disk
      mount_info = `lsblk -n -o MOUNTPOINT #{device} 2>/dev/null`.strip
      if mount_info.include?('/') || mount_info.include?('/boot')
        puts "\nWARNING: This device contains system partitions!"
        print "Are you ABSOLUTELY SURE you want to continue? (y/N) "
        response = $stdin.gets.chomp
        return nil unless response.downcase == 'y'
      end

      device
    end

    def check_and_wipe_iso(device)
      # Check if device contains an ISO image
      blkid_output = `sudo blkid #{device} 2>/dev/null`.strip

      if blkid_output.include?('TYPE="iso9660"')
        iso_label = blkid_output[/LABEL="([^"]*)"/, 1] || "Unknown"
        puts "\nDetected ISO image on #{device}: #{iso_label}"
        puts "This appears to be an ISO image written directly to the device."
        puts "Ventoy installation requires wiping this ISO image first."

        print "Wipe the ISO image and prepare device for Ventoy? (y/N) "
        response = $stdin.gets.chomp
        if response.downcase == 'y'
          puts "Wiping device (this may take a moment)..."
          sudo_command("dd if=/dev/zero of=#{device} bs=1M count=100 status=progress")
          puts "Device wiped successfully"

          # Force kernel to re-read the partition table
          sudo_command("partprobe #{device}")
          sleep 2
        else
          puts "Cannot proceed without wiping the ISO. Exiting."
          return false
        end
      end

      true
    end

    def install_ventoy(device)
      ventoy_script = @config.ventoy_dir / 'Ventoy2Disk.sh'

      unless ventoy_script.exist?
        puts "Error: Ventoy script not found at #{ventoy_script}"
        puts "Run 'ppm install pim' to download Ventoy binaries"
        return false
      end

      puts "\nInstalling Ventoy to #{device}..."
      puts "This will:"
      puts "  - Create 2 partitions on #{device}"
      puts "  - Partition 1: VTOYEFI (FAT) for boot files"
      puts "  - Partition 2: Ventoy (exFAT) for ISO files"

      # Use expect to handle both interactive prompts
      expect_script = <<~EOF
        spawn sudo sh #{ventoy_script} -i #{device}
        expect {
          "Continue? (y/n)" { send "y\\r"; exp_continue }
          "Double-check. Continue? (y/n)" { send "y\\r"; exp_continue }
          eof
        }
      EOF

      puts "Running Ventoy installation..."
      output = `expect -c '#{expect_script}' 2>&1`

      if output.include?("success") || output.include?("done")
        puts "\nVentoy installed successfully!"
        # Give system time to update partition table
        sleep 2
        system("sudo partprobe #{device}")

        # Fix partition bootable flags
        puts "Fixing partition bootable flags..."
        fix_partition_flags(device)

        show_device_info(device)
        true
      else
        puts "\nInstallation output:"
        puts output
        false
      end
    end

    def fix_partition_flags(device)
      base_device = device.gsub(/\d+$/, '')

      # Set bootable flag on partition 2 (EFI partition)
      puts "  Setting bootable flag on EFI partition..."
      sudo_command("sfdisk -A #{base_device} 2")

      # Update partition table
      sudo_command("partprobe #{base_device}")
      sleep 1

      puts "Partition flags fixed - EFI partition is now bootable"
    end

    def mount_device(device)
      mount_point = @config.mount_point
      FileUtils.mkdir_p(mount_point)

      if mounted?(mount_point)
        puts "Device already mounted at #{mount_point}"
        return true
      end

      unless File.exist?(device)
        puts "Error: Device #{device} does not exist"
        return false
      end

      puts "Mounting #{device} to #{mount_point}..."

      # Try exfat first with rw option
      _, stderr, status = Open3.capture3(
        "sudo mount -t exfat -o rw,uid=#{Process.uid},gid=#{Process.gid} #{device} #{mount_point}"
      )
      unless status.success?
        puts "ExFAT mount failed, trying auto-detect with rw..."
        _, stderr, status = Open3.capture3(
          "sudo mount -o rw,uid=#{Process.uid},gid=#{Process.gid} #{device} #{mount_point}"
        )
        unless status.success?
          puts "Error mounting device: #{stderr}"
          return false
        end
      end

      # Verify the mount is writable
      test_file = mount_point / '.write_test'
      unless system("touch #{test_file} 2>/dev/null && rm -f #{test_file} 2>/dev/null")
        puts "Warning: Mount point appears to be read-only"

        # Try remounting with proper permissions
        sudo_command("umount #{mount_point}")
        _, stderr, status = Open3.capture3(
          "sudo mount -t exfat -o rw,uid=#{Process.uid},gid=#{Process.gid},umask=0000 #{device} #{mount_point}"
        )
        unless status.success?
          puts "Error: Cannot mount device as writable: #{stderr}"
          return false
        end
      end

      puts "Mounted successfully as read-write"
      true
    end

    def unmount_device
      mount_point = @config.mount_point

      unless mounted?(mount_point)
        puts "Device not mounted at #{mount_point}"
        return true
      end

      puts "Unmounting #{mount_point}..."
      sudo_command("sync")  # Ensure all writes are flushed
      sudo_command("umount #{mount_point}")
      puts "Unmounted successfully"
      true
    end

    def copy_isos
      mount_point = @config.mount_point
      iso_dir = @config.iso_dir

      unless mounted?(mount_point)
        puts "Error: No device mounted at #{mount_point}"
        puts "Use 'pim ventoy copy DEVICE' to mount and copy ISOs"
        return false
      end

      unless iso_dir.exist?
        puts "Error: ISO directory #{iso_dir} does not exist"
        return false
      end

      # Use pim/iso to get the ISO catalog
      require 'pim/iso'
      iso_config = PimIso::Config.new
      isos = iso_config.isos

      if isos.empty?
        puts "No ISOs configured. Use 'pim iso add' to add some."
        return false
      end

      copied = 0
      skipped = 0

      isos.each do |key, iso|
        filename = iso['filename'] || "#{key}.iso"
        source = iso_dir / filename
        next unless source.exist?

        dest = mount_point / filename

        if dest.exist? && dest.size == source.size
          puts "Skipping #{filename} (already exists with same size)"
          skipped += 1
          next
        end

        puts "Copying #{filename}..."
        FileUtils.cp(source, dest, verbose: true)
        copied += 1
      end

      puts "\nSummary: #{copied} copied, #{skipped} skipped"
      true
    end

    def ventoy_installed?(device)
      base_device = device.gsub(/\d+$/, '')
      output = `sudo fdisk -l #{base_device} 2>/dev/null`
      output.include?('VTOYEFI')
    end

    def status(device)
      if ventoy_installed?(device)
        puts "Ventoy is installed on #{device}"
        show_device_info(device)
        true
      else
        puts "Ventoy is not installed on #{device}"
        false
      end
    end

    def show_config
      puts "Ventoy Configuration"
      puts
      puts "  version:     #{@config.version || '(not set)'}"
      puts "  dir:         #{@config.dir || '(not set)'}"
      puts "  file:        #{@config.file || '(not set)'}"
      puts "  checksum:    #{@config.checksum || '(not set)'}"
      puts "  device:      #{@config.device || '(not set)'}"
      puts
      puts "Paths:"
      puts "  ventoy_dir:  #{@config.ventoy_dir}"
      puts "  mount_point: #{@config.mount_point}"
      puts "  iso_dir:     #{@config.iso_dir}"
      puts
      puts "Status:"
      puts "  installed:   #{@config.ventoy_dir.exist? ? 'yes' : 'no'}"
    end

    private

    def mounted?(mount_point)
      system("mountpoint -q #{mount_point}")
    end

    def show_device_info(device)
      base_device = device.gsub(/\d+$/, '')
      puts `sudo fdisk -l #{base_device} 2>/dev/null | grep -E '(Disk|VTOYEFI|exfat)'`
    end

    def sudo_command(cmd)
      full_cmd = "sudo #{cmd}"
      puts "Running: #{full_cmd}"
      stdout, stderr, status = Open3.capture3(full_cmd)
      unless status.success?
        puts "Command failed: #{full_cmd}"
        puts stderr
        return nil
      end
      stdout
    end
  end

  # CLI interface for pim-ventoy
  class CLI < Thor
    def self.exit_on_failure? = true
    remove_command :tree

    desc 'prepare [DEVICE]', 'Install Ventoy to USB device'
    option :force, aliases: '-f', type: :boolean, desc: 'Force installation without confirmation'
    def prepare(device = nil)
      device ||= manager.config.device
      unless device
        puts "Error: No device specified and no default device in config"
        puts "Usage: pim ventoy prepare /dev/sdX"
        exit 1
      end

      device = manager.validate_device(device)
      exit 1 unless device

      unless manager.verify_ventoy_install
        exit 1
      end

      unless manager.check_and_wipe_iso(device)
        exit 1
      end

      unless options[:force]
        print "WARNING: This will destroy all data on #{device}. Continue? (y/N) "
        response = $stdin.gets.chomp
        exit 1 unless response.downcase == 'y'
      end

      manager.install_ventoy(device)
    end

    desc 'copy [DEVICE]', 'Mount device and copy ISOs from pim-iso cache'
    def copy(device = nil)
      device ||= manager.config.device

      # If device looks like a whole disk, use partition 1
      if device && device !~ /\d+$/
        device = "#{device}1"
        puts "Using partition: #{device}"
      end

      unless device
        puts "Error: No device specified and no default device in config"
        puts "Usage: pim ventoy copy /dev/sdX1"
        exit 1
      end

      unless manager.mount_device(device)
        exit 1
      end

      begin
        manager.copy_isos
      ensure
        manager.unmount_device
      end
    end

    desc 'status [DEVICE]', 'Check Ventoy installation status'
    def status(device = nil)
      device ||= manager.config.device
      unless device
        puts "Error: No device specified and no default device in config"
        puts "Usage: pim ventoy status /dev/sdX"
        exit 1
      end

      manager.status(device)
    end

    desc 'config', 'Show ventoy configuration'
    def config
      manager.show_config
    end

    private

    def manager
      @manager ||= Manager.new
    end
  end
end
