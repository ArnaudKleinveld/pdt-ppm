# frozen_string_literal: true

require 'open3'
require 'json'
require 'pty'
require 'timeout'
require 'socket'

module PimQemu
  # Disk image operations via qemu-img
  class DiskImage
    class Error < StandardError; end

    attr_reader :path

    def initialize(path)
      @path = File.expand_path(path)
    end

    # Create a new disk image
    def self.create(path, size:, format: 'qcow2')
      FileUtils.mkdir_p(File.dirname(path))

      cmd = ['qemu-img', 'create', '-f', format, path, size]
      stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        raise Error, "Failed to create disk image: #{stderr}"
      end

      new(path)
    end

    # Get disk image info
    def info
      cmd = ['qemu-img', 'info', '--output=json', @path]
      stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        raise Error, "Failed to get image info: #{stderr}"
      end

      JSON.parse(stdout)
    end

    # Check if image exists
    def exist?
      File.exist?(@path)
    end

    # Get actual size on disk
    def actual_size
      return nil unless exist?

      info['actual-size']
    end

    # Get virtual size
    def virtual_size
      return nil unless exist?

      info['virtual-size']
    end

    # Convert to another format
    def convert(output_path, format: 'qcow2', compress: false)
      cmd = ['qemu-img', 'convert']
      cmd += ['-c'] if compress
      cmd += ['-O', format, @path, output_path]

      stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        raise Error, "Failed to convert image: #{stderr}"
      end

      DiskImage.new(output_path)
    end

    # Resize the image
    def resize(size)
      cmd = ['qemu-img', 'resize', @path, size]
      stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        raise Error, "Failed to resize image: #{stderr}"
      end

      true
    end
  end

  # QEMU command builder for different architectures
  class CommandBuilder
    def initialize(arch:, memory: 2048, cpus: 2, display: false, serial: nil)
      @arch = arch
      @memory = memory
      @cpus = cpus
      @display = display
      @serial = serial
      @drives = []
      @cdrom = nil
      @netdevs = []
      @extra_args = []
    end

    # Add a disk drive
    def add_drive(path, format: 'qcow2', if_type: 'virtio', index: 0)
      @drives << { path: path, format: format, if_type: if_type, index: index }
      self
    end

    # Set CD-ROM/ISO
    def set_cdrom(path)
      @cdrom = path
      self
    end

    # Add user-mode networking with port forwarding
    def add_user_net(host_port:, guest_port: 22, id: 'net0')
      @netdevs << {
        type: 'user',
        id: id,
        host_port: host_port,
        guest_port: guest_port
      }
      self
    end

    # Add kernel boot parameters (for preseed)
    def set_kernel_args(kernel_args)
      @kernel_args = kernel_args
      self
    end

    # Add extra QEMU arguments
    def extra_args(*args)
      @extra_args += args.flatten
      self
    end

    # Build the command array
    def build
      cmd = [qemu_binary]

      # Machine and acceleration
      cmd += machine_args

      # CPU and memory
      cmd += ['-smp', @cpus.to_s]
      cmd += ['-m', @memory.to_s]

      # Display
      unless @display
        cmd += ['-nographic']
      end

      # Drives
      @drives.each do |drive|
        cmd += ['-drive', "file=#{drive[:path]},format=#{drive[:format]},if=#{drive[:if_type]},index=#{drive[:index]}"]
      end

      # CD-ROM
      if @cdrom
        cmd += ['-cdrom', @cdrom]
        cmd += ['-boot', 'd'] # Boot from CD
      end

      # Network
      @netdevs.each do |net|
        case net[:type]
        when 'user'
          netdev = "user,id=#{net[:id]},hostfwd=tcp::#{net[:host_port]}-:#{net[:guest_port]}"
          cmd += ['-netdev', netdev]
          cmd += ['-device', "#{virtio_net_device},netdev=#{net[:id]}"]
        end
      end

      # Serial console
      if @serial
        cmd += ['-serial', @serial]
      elsif !@display
        cmd += ['-serial', 'mon:stdio']
      end

      # Extra args
      cmd += @extra_args unless @extra_args.empty?

      cmd
    end

    # Get command as string (for display)
    def to_s
      build.map { |arg| arg.include?(' ') ? "\"#{arg}\"" : arg }.join(' ')
    end

    private

    def qemu_binary
      case @arch
      when 'arm64', 'aarch64'
        'qemu-system-aarch64'
      when 'x86_64', 'amd64'
        'qemu-system-x86_64'
      else
        raise "Unsupported architecture: #{@arch}"
      end
    end

    def machine_args
      case @arch
      when 'arm64', 'aarch64'
        if macos?
          # Apple Silicon with HVF
          ['-machine', 'virt,accel=hvf,highmem=on', '-cpu', 'host']
        else
          # Linux ARM64 with KVM or TCG
          if File.exist?('/dev/kvm')
            ['-machine', 'virt,accel=kvm', '-cpu', 'host']
          else
            ['-machine', 'virt', '-cpu', 'cortex-a72']
          end
        end
      when 'x86_64', 'amd64'
        if macos?
          ['-machine', 'q35,accel=hvf', '-cpu', 'host']
        else
          if File.exist?('/dev/kvm')
            ['-machine', 'q35,accel=kvm', '-cpu', 'host']
          else
            ['-machine', 'q35', '-cpu', 'qemu64']
          end
        end
      else
        raise "Unsupported architecture: #{@arch}"
      end
    end

    def virtio_net_device
      case @arch
      when 'arm64', 'aarch64'
        'virtio-net-pci'
      when 'x86_64', 'amd64'
        'virtio-net-pci'
      else
        'e1000'
      end
    end

    def macos?
      RUBY_PLATFORM.include?('darwin')
    end
  end

  # QEMU VM process management
  class VM
    class Error < StandardError; end

    attr_reader :pid, :ssh_port

    def initialize(command:, ssh_port: nil)
      @command = command
      @ssh_port = ssh_port
      @pid = nil
      @process = nil
    end

    # Start the VM process
    def start
      @stdin, @stdout, @stderr, @process = Open3.popen3(*@command)
      @pid = @process.pid

      # Give QEMU a moment to start
      sleep 2

      # Check if process is still running
      unless running?
        output = @stderr.read rescue ''
        raise Error, "VM failed to start: #{output}"
      end

      self
    end

    # Start VM in background and return immediately
    def start_background(detach: true)
      @pid = spawn(*@command, [:out, :err] => '/dev/null')
      Process.detach(@pid) if detach
      @detached = detach

      sleep 2
      self
    end

    # Start VM with serial output going directly to the terminal
    def start_console(detach: true)
      @pid = spawn(*@command)
      Process.detach(@pid) if detach
      @detached = detach

      sleep 2
      self
    end

    # Wait for VM process to exit (only works when started with detach: false)
    def wait_for_exit(timeout: 3600, poll_interval: 10)
      deadline = Time.now + timeout

      while Time.now < deadline
        begin
          pid, status = Process.waitpid2(@pid, Process::WNOHANG)
          if pid
            @pid = nil
            return status.exitstatus || 0
          end
        rescue Errno::ECHILD
          @pid = nil
          return 0
        end

        remaining = (deadline - Time.now).to_i
        yield(remaining) if block_given?
        sleep(poll_interval)
      end

      nil
    end

    # Check if VM is running
    def running?
      return false unless @pid

      begin
        Process.kill(0, @pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true # Process exists but we can't signal it
      end
    end

    # Stop the VM gracefully (send ACPI shutdown)
    def shutdown(timeout: 60)
      return unless @pid && running?

      # Send SIGTERM first
      Process.kill('TERM', @pid)

      # Wait for graceful shutdown
      deadline = Time.now + timeout
      while Time.now < deadline && running?
        sleep 1
      end

      # Force kill if still running
      if running?
        Process.kill('KILL', @pid)
        sleep 1
      end
    end

    # Force stop the VM
    def kill
      return unless @pid

      begin
        Process.kill('KILL', @pid)
      rescue Errno::ESRCH
        # Already dead
      end
    end

    # Wait for SSH port to be available (verifies SSH banner, not just TCP)
    def wait_for_ssh(timeout: 1800, poll_interval: 10, &block)
      return false unless @ssh_port

      deadline = Time.now + timeout
      attempt = 0

      while Time.now < deadline
        attempt += 1
        begin
          socket = TCPSocket.new('127.0.0.1', @ssh_port)
          ready = IO.select([socket], nil, nil, 10)
          if ready
            banner = socket.gets
            socket.close
            return true if banner&.start_with?('SSH-')
          else
            socket.close
          end
        rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, IOError
          # Port not ready yet
        end

        remaining = (deadline - Time.now).to_i
        block.call(attempt, remaining) if block_given?
        sleep(poll_interval)
      end

      false
    end

    # Wait for process to exit
    def wait
      return nil unless @process

      @process.value.exitstatus
    end
  end

  # Find an available port
  def self.find_available_port(start_port: 2222, max_attempts: 100)
    (start_port..start_port + max_attempts).each do |port|
      begin
        socket = TCPServer.new('127.0.0.1', port)
        socket.close
        return port
      rescue Errno::EADDRINUSE
        next
      end
    end
    raise "No available port found in range #{start_port}-#{start_port + max_attempts}"
  end

  # Check if qemu is installed
  def self.check_dependencies
    missing = []

    %w[qemu-system-aarch64 qemu-system-x86_64 qemu-img].each do |cmd|
      _, status = Open3.capture2("which #{cmd}")
      missing << cmd unless status.success?
    end

    missing
  end
end
