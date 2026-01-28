# frozen_string_literal: true

require 'fileutils'
require 'time'

module PimBuild
  # Local builder - builds images on the current machine
  class LocalBuilder
    class BuildError < StandardError; end

    def initialize(config:, profile:, profile_name:, arch:, iso_path:, iso_key:)
      @config = config
      @profile = profile
      @profile_name = profile_name
      @arch = arch
      @iso_path = iso_path
      @iso_key = iso_key
      @ssh_port = nil
      @vm = nil
      @server_thread = nil
    end

    def build(cache_key:, scripts: [], output_callback: nil)
      @output = output_callback || method(:default_output)
      @scripts = scripts

      begin
        output(:info, "Starting build for #{@profile_name}-#{@arch}")

        # 1. Create disk image
        image_path = create_disk_image

        # 2. Find available SSH port
        @ssh_port = PimQemu.find_available_port

        # 3. Start preseed server in background
        start_preseed_server

        # 4. Start QEMU with ISO boot
        start_vm(image_path)

        # 5. Wait for installation to complete and SSH to become available
        wait_for_ssh

        # 6. Run provisioning scripts
        run_scripts

        # 7. Finalize image
        finalize_image

        # 8. Shutdown VM
        shutdown_vm

        # 9. Register in registry
        register_image(image_path, cache_key)

        output(:success, "Build complete: #{image_path}")
        image_path
      rescue StandardError => e
        output(:error, "Build failed: #{e.message}")
        cleanup
        raise BuildError, e.message
      ensure
        cleanup
      end
    end

    private

    def output(level, message)
      @output.call(level, message)
    end

    def default_output(level, message)
      prefix = case level
               when :info then '  '
               when :success then 'OK '
               when :error then 'FAIL '
               when :progress then '... '
               else '  '
               end
      puts "#{prefix}#{message}"
    end

    def create_disk_image
      timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
      filename = "#{@profile_name}-#{@arch}-#{timestamp}.qcow2"
      path = File.join(@config.image_dir, filename)

      output(:info, "Creating disk image: #{filename}")
      FileUtils.mkdir_p(@config.image_dir)

      PimQemu::DiskImage.create(path, size: disk_size, format: 'qcow2')
      output(:info, "Disk image created: #{disk_size}")

      path
    end

    def disk_size
      # Profile can override global disk size
      @profile.data.dig('build', 'disk_size') || @config.disk_size
    end

    def memory
      @profile.data.dig('build', 'memory') || @config.memory
    end

    def cpus
      @profile.data.dig('build', 'cpus') || @config.cpus
    end

    def start_preseed_server
      output(:info, 'Starting preseed server')

      # Find available port for preseed server
      @preseed_port = PimQemu.find_available_port(start_port: 8080)

      # Create server instance using existing Pim::Server
      @server = Pim::Server.new(
        profile: @profile,
        port: @preseed_port,
        verbose: false,
        preseed_name: @profile_name,
        install_name: @profile_name
      )

      # Start in background thread
      @server_thread = Thread.new do
        # Suppress output from server
        original_stdout = $stdout.dup
        $stdout.reopen('/dev/null', 'w')
        begin
          @server.start
        rescue StandardError
          # Server stopped
        ensure
          $stdout.reopen(original_stdout)
        end
      end

      # Give server time to start
      sleep 1

      output(:info, "Preseed server running on port #{@preseed_port}")
    end

    def preseed_url
      ip = local_ip
      "http://#{ip}:#{@preseed_port}/preseed.cfg"
    end

    def local_ip
      Socket.ip_address_list
            .detect { |addr| addr.ipv4? && !addr.ipv4_loopback? }
            &.ip_address || '127.0.0.1'
    end

    def start_vm(image_path)
      output(:info, 'Starting QEMU VM')

      builder = PimQemu::CommandBuilder.new(
        arch: @arch,
        memory: memory,
        cpus: cpus,
        display: false
      )

      builder.add_drive(image_path, format: 'qcow2')
      builder.set_cdrom(@iso_path)
      builder.add_user_net(host_port: @ssh_port, guest_port: 22)

      # Add boot parameters for automated install
      # For Debian preseed, we need to pass boot parameters via kernel args
      # This requires extracting kernel from ISO which is complex
      # For now, user must manually configure boot in preseed or use autoinstall

      # Add EFI firmware for ARM64
      if @arch == 'arm64'
        efi_firmware = find_efi_firmware
        if efi_firmware
          builder.extra_args('-bios', efi_firmware)
        else
          output(:info, 'Warning: No EFI firmware found, VM may not boot')
        end
      end

      @vm = PimQemu::VM.new(command: builder.build, ssh_port: @ssh_port)
      @vm.start_background

      output(:info, "VM started (PID: #{@vm.pid})")
      output(:info, "SSH will be available on localhost:#{@ssh_port}")
      output(:info, "Preseed URL: #{preseed_url}")
      output(:info, '')
      output(:info, 'Boot the installer with these parameters:')
      output(:info, "  auto=true priority=critical preseed/url=#{preseed_url}")
    end

    def find_efi_firmware
      # Common locations for AAVMF/QEMU UEFI firmware
      paths = [
        '/opt/homebrew/share/qemu/edk2-aarch64-code.fd',
        '/usr/local/share/qemu/edk2-aarch64-code.fd',
        '/usr/share/qemu/edk2-aarch64-code.fd',
        '/usr/share/AAVMF/AAVMF_CODE.fd',
        '/usr/share/qemu-efi-aarch64/QEMU_EFI.fd'
      ]

      paths.find { |p| File.exist?(p) }
    end

    def wait_for_ssh
      output(:info, 'Waiting for installation to complete and SSH to become available...')
      output(:info, "(timeout: #{@config.ssh_timeout}s)")

      success = @vm.wait_for_ssh(timeout: @config.ssh_timeout, poll_interval: 30) do |attempt, remaining|
        output(:progress, "Attempt #{attempt}, #{remaining}s remaining...")
      end

      unless success
        raise BuildError, 'Timed out waiting for SSH'
      end

      output(:success, 'SSH is available')

      # Additional wait for system to stabilize
      sleep 5
    end

    def run_scripts
      return if @scripts.empty?

      output(:info, "Running #{@scripts.size} provisioning script(s)")

      require_relative '../ssh'

      ssh = PimSSH::Connection.new(
        host: '127.0.0.1',
        port: @ssh_port,
        user: @config.ssh_user,
        password: @profile.data['password']
      )

      @scripts.each_with_index do |script_path, index|
        script_name = File.basename(script_path)
        output(:info, "[#{index + 1}/#{@scripts.size}] Running #{script_name}")

        # Upload script
        remote_path = "/tmp/pim-script-#{index}.sh"
        ssh.upload(script_path, remote_path)

        # Make executable and run
        result = ssh.execute("chmod +x #{remote_path} && #{remote_path}", sudo: true)

        if result[:exit_code] != 0
          output(:error, "Script #{script_name} failed (exit code: #{result[:exit_code]})")
          output(:error, result[:stderr]) unless result[:stderr].empty?
          raise BuildError, "Script #{script_name} failed"
        end

        output(:success, "#{script_name} completed")
      end
    end

    def finalize_image
      output(:info, 'Finalizing image')

      require_relative '../ssh'

      ssh = PimSSH::Connection.new(
        host: '127.0.0.1',
        port: @ssh_port,
        user: @config.ssh_user,
        password: @profile.data['password']
      )

      # Clean cloud-init if present
      ssh.execute('cloud-init clean --logs 2>/dev/null || true', sudo: true)

      # Truncate machine-id for unique ID on first boot
      ssh.execute('truncate -s 0 /etc/machine-id', sudo: true)

      # Clean apt cache
      ssh.execute('apt-get clean 2>/dev/null || true', sudo: true)

      # Clear logs
      ssh.execute('find /var/log -type f -exec truncate -s 0 {} \\; 2>/dev/null || true', sudo: true)

      # Remove SSH host keys (regenerated on first boot)
      ssh.execute('rm -f /etc/ssh/ssh_host_* 2>/dev/null || true', sudo: true)

      output(:success, 'Image finalized')
    end

    def shutdown_vm
      output(:info, 'Shutting down VM')

      if @vm&.running?
        require_relative '../ssh'

        begin
          ssh = PimSSH::Connection.new(
            host: '127.0.0.1',
            port: @ssh_port,
            user: @config.ssh_user,
            password: @profile.data['password']
          )
          ssh.execute('shutdown -h now', sudo: true)
          sleep 5
        rescue StandardError
          # SSH might fail during shutdown, that's OK
        end

        @vm.shutdown(timeout: 30)
      end

      output(:success, 'VM stopped')
    end

    def register_image(image_path, cache_key)
      output(:info, 'Registering image in registry')

      require_relative '../registry'

      registry = PimRegistry::Registry.new(image_dir: @config.image_dir)
      registry.register(
        profile: @profile_name,
        arch: @arch,
        path: image_path,
        iso: @iso_key,
        cache_key: cache_key
      )

      output(:success, 'Image registered')
    end

    def cleanup
      # Stop server thread
      if @server_thread&.alive?
        Thread.kill(@server_thread)
      end

      # Kill VM if still running
      if @vm&.running?
        @vm.kill
      end
    end
  end
end
