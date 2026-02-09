# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'time'
require 'tmpdir'

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

    def build(cache_key:, scripts: [], output_callback: nil, vnc: nil, console: false, console_log: nil)
      @output = output_callback || method(:default_output)
      @scripts = scripts
      @vnc = vnc
      @console = console
      @console_log = console_log

      begin
        output(:info, "Starting build for #{@profile_name}-#{@arch}")

        # 1. Create disk image
        image_path = create_disk_image

        # 2. Find available SSH port
        @ssh_port = PimQemu.find_available_port

        # 3. Start preseed server in background
        start_preseed_server

        # 4. Extract kernel/initrd for direct boot (bypasses GRUB)
        extract_installer_kernel

        # 5. Set up EFI pflash (shared between install and boot phases)
        setup_efi_pflash if @arch == 'arm64'

        # === Phase 1: Installation ===
        # 5. Start QEMU with installer kernel + preseed (halts when done)
        run_installer(image_path)

        # 6. Wait for installer to finish (VM powers off)
        wait_for_install

        # === Phase 2: Boot from disk ===
        # 7. Start QEMU from installed disk
        boot_vm(image_path)

        # 8. Wait for SSH
        wait_for_ssh

        # 9. Run provisioning scripts
        run_scripts

        # 10. Finalize image
        finalize_image

        # 11. Shutdown VM
        shutdown_vm

        # 12. Save EFI vars alongside image (for booting later)
        save_efi_vars(image_path) if @arch == 'arm64'

        # 13. Register in registry
        register_image(image_path, cache_key)

        output(:success, "Build complete: #{image_path}")
        image_path
      rescue Interrupt
        output(:info, "\nBuild interrupted")
        cleanup
        exit 130
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
               when :console then '[console] '
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

      @preseed_port = PimQemu.find_available_port(start_port: 8080)

      @server = Pim::Server.new(
        profile: @profile,
        port: @preseed_port,
        verbose: false,
        preseed_name: @profile_name,
        install_name: @profile_name
      )

      # Suppress server output during startup, then restore before spawning QEMU
      # NOTE: $stdout.reopen is process-wide — must restore before spawn or
      # child processes inherit /dev/null as their stdout
      saved_stdout = $stdout.dup
      $stdout.reopen('/dev/null', 'w')

      @server_thread = Thread.new do
        begin
          @server.start
        rescue StandardError
          # Server stopped
        end
      end

      # Give server time to start (WEBrick installs its own SIGINT handler)
      sleep 1

      # Restore stdout before any child processes are spawned
      $stdout.reopen(saved_stdout)
      saved_stdout.close

      # Restore SIGINT so Ctrl-C interrupts the build, not just WEBrick
      trap('INT') { Thread.main.raise(Interrupt) }

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

    def extract_installer_kernel
      output(:info, 'Extracting kernel and initrd from ISO')

      @kernel_dir = Dir.mktmpdir('pim-kernel-')

      install_subdir = case @arch
                       when 'arm64' then 'install.a64'
                       when 'x86_64' then 'install.amd'
                       else raise BuildError, "Unsupported architecture: #{@arch}"
                       end

      vmlinuz = "#{install_subdir}/vmlinuz"
      initrd = "#{install_subdir}/initrd.gz"

      _, stderr, status = Open3.capture3(
        'bsdtar', 'xf', @iso_path, '-C', @kernel_dir, vmlinuz, initrd
      )

      unless status.success?
        FileUtils.rm_rf(@kernel_dir)
        raise BuildError, "Failed to extract kernel from ISO: #{stderr}"
      end

      @kernel_path = File.join(@kernel_dir, vmlinuz)
      @initrd_path = File.join(@kernel_dir, initrd)

      unless File.exist?(@kernel_path) && File.exist?(@initrd_path)
        FileUtils.rm_rf(@kernel_dir)
        raise BuildError, 'Kernel or initrd not found in ISO'
      end

      output(:info, "Extracted #{vmlinuz} and #{initrd}")
    end

    def setup_efi_pflash
      @efi_code_path = find_efi_firmware
      raise BuildError, 'EFI firmware (code) not found' unless @efi_code_path

      vars_template = find_efi_vars_template
      @efi_vars_path = File.join(@kernel_dir, 'efivars.fd')

      if vars_template
        FileUtils.cp(vars_template, @efi_vars_path)
      else
        # Create empty 64MB vars file
        File.open(@efi_vars_path, 'wb') { |f| f.write("\0" * (64 * 1024 * 1024)) }
      end

      output(:info, 'EFI pflash configured')
    end

    def add_efi_pflash(builder)
      builder.extra_args(
        '-drive', "if=pflash,format=raw,file=#{@efi_code_path},readonly=on",
        '-drive', "if=pflash,format=raw,file=#{@efi_vars_path}"
      )
    end

    def find_efi_vars_template
      paths = [
        '/opt/homebrew/share/qemu/edk2-arm-vars.fd',
        '/usr/local/share/qemu/edk2-arm-vars.fd',
        '/usr/share/qemu/edk2-arm-vars.fd',
        '/usr/share/AAVMF/AAVMF_VARS.fd'
      ]
      paths.find { |p| File.exist?(p) }
    end

    # --- Phase 1: Run the installer with direct kernel boot ---

    def run_installer(image_path)
      output(:info, 'Starting installer VM')

      serial_console = @arch == 'arm64' ? 'ttyAMA0' : 'ttyS0'
      use_display = !@vnc.nil?
      serial = if @console_log
                 "file:#{@console_log}"
               elsif @console
                 'stdio'
               elsif use_display
                 'null'
               else
                 nil
               end

      builder = PimQemu::CommandBuilder.new(
        arch: @arch,
        memory: memory,
        cpus: cpus,
        display: use_display,
        serial: serial
      )

      builder.add_drive(image_path, format: 'qcow2')
      builder.set_cdrom(@iso_path)
      builder.add_user_net(host_port: @ssh_port, guest_port: 22)

      # EFI firmware via pflash (so installer detects EFI and installs EFI GRUB)
      add_efi_pflash(builder) if @arch == 'arm64'

      # Direct kernel boot with preseed
      consoles = []
      consoles << "console=#{serial_console},115200n8" if !@vnc || @console || @console_log
      consoles << 'console=tty0' if @vnc
      append_parts = [
        'auto=true', 'priority=critical',
        "preseed/url=#{preseed_url}",
        'grub-installer/force-efi-extra-removable=true',
        *consoles,
        '---'
      ]
      builder.extra_args('-kernel', @kernel_path, '-initrd', @initrd_path,
                         '-append', append_parts.join(' '))

      # QEMU exits when guest reboots (instead of restarting the installer)
      builder.extra_args('-no-reboot')

      # VNC display + virtual GPU/keyboard for ARM64
      if @vnc
        builder.extra_args('-vnc', ":#{@vnc}")
        if @arch == 'arm64'
          builder.extra_args('-device', 'virtio-gpu-pci,xres=1024,yres=768')
          builder.extra_args('-device', 'usb-ehci')
          builder.extra_args('-device', 'usb-kbd')
          builder.extra_args('-device', 'usb-tablet')
        end
      end

      @vm = PimQemu::VM.new(command: builder.build, ssh_port: @ssh_port)

      if @console && !@console_log
        @vm.start_console(detach: false)
      else
        @vm.start_background(detach: false)
      end

      output(:info, "Installer started (PID: #{@vm.pid})")
      output(:info, "Preseed URL: #{preseed_url}")

      if @vnc
        output(:info, "VNC available on localhost:#{5900 + @vnc}")
      end

      if @console_log
        output(:info, "Console log: #{@console_log}")
        output(:info, "Tail with: tail -f #{@console_log}")
      end
    end

    def wait_for_install
      output(:info, 'Waiting for installation to complete (VM will power off)...')

      result = @vm.wait_for_exit(timeout: @config.ssh_timeout, poll_interval: 30) do |remaining|
        output(:progress, "Installing... #{remaining}s remaining")
      end

      if result.nil?
        raise BuildError, 'Installation timed out'
      end

      output(:success, 'Installation complete — VM powered off')
      @vm = nil
    end

    # --- Phase 2: Boot the installed system from disk ---

    def boot_vm(image_path)
      output(:info, 'Booting installed system from disk')

      serial_console = @arch == 'arm64' ? 'ttyAMA0' : 'ttyS0'
      use_display = !@vnc.nil?
      serial = if @console_log
                 "file:#{@console_log}"
               elsif @console
                 'stdio'
               elsif use_display
                 'null'
               else
                 nil
               end

      builder = PimQemu::CommandBuilder.new(
        arch: @arch,
        memory: memory,
        cpus: cpus,
        display: use_display,
        serial: serial
      )

      builder.add_drive(image_path, format: 'qcow2')
      builder.add_user_net(host_port: @ssh_port, guest_port: 22)

      # No -kernel, -initrd, -cdrom — boot from installed disk via EFI GRUB
      # Uses same pflash vars from phase 1 (has boot entries from installer)
      if @arch == 'arm64'
        add_efi_pflash(builder)
      end

      # VNC display
      if @vnc
        builder.extra_args('-vnc', ":#{@vnc}")
        if @arch == 'arm64'
          builder.extra_args('-device', 'virtio-gpu-pci,xres=1024,yres=768')
          builder.extra_args('-device', 'usb-ehci')
          builder.extra_args('-device', 'usb-kbd')
          builder.extra_args('-device', 'usb-tablet')
        end
      end

      @vm = PimQemu::VM.new(command: builder.build, ssh_port: @ssh_port)

      if @console && !@console_log
        @vm.start_console
      else
        @vm.start_background
      end

      output(:info, "VM started (PID: #{@vm.pid})")
      output(:info, "SSH will be available on localhost:#{@ssh_port}")
    end

    def find_efi_firmware
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
      output(:info, 'Waiting for SSH to become available...')
      output(:info, "(timeout: #{@config.ssh_timeout}s)")

      success = @vm.wait_for_ssh(timeout: @config.ssh_timeout, poll_interval: 10) do |attempt, remaining|
        output(:progress, "Attempt #{attempt}, #{remaining}s remaining...")
      end

      unless success
        raise BuildError, 'Timed out waiting for SSH'
      end

      output(:success, 'SSH is available')

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

        remote_path = "/tmp/pim-script-#{index}.sh"
        ssh.upload(script_path, remote_path)

        ssh.execute("chmod +x #{remote_path}", sudo: true)
        result = ssh.execute(remote_path, sudo: true)

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

      ssh.execute('cloud-init clean --logs 2>/dev/null || true', sudo: true)
      ssh.execute('truncate -s 0 /etc/machine-id', sudo: true)
      ssh.execute('apt-get clean 2>/dev/null || true', sudo: true)
      ssh.execute('find /var/log -type f -exec truncate -s 0 {} \\; 2>/dev/null || true', sudo: true)
      ssh.execute('rm -f /etc/ssh/ssh_host_* && dpkg-reconfigure openssh-server', sudo: true)

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

    def save_efi_vars(image_path)
      return unless @efi_vars_path && File.exist?(@efi_vars_path)

      vars_path = image_path.sub(/\.qcow2$/, '-efivars.fd')
      FileUtils.cp(@efi_vars_path, vars_path)
      output(:info, "EFI vars saved: #{File.basename(vars_path)}")
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
      FileUtils.rm_rf(@kernel_dir) if @kernel_dir

      if @server_thread&.alive?
        Thread.kill(@server_thread)
      end

      if @vm&.running?
        @vm.kill
      end
    end
  end
end
