# frozen_string_literal: true

require 'net/ssh'
require 'net/scp'
require 'timeout'

module PimSSH
  # SSH connection wrapper with retry and timeout support
  class Connection
    DEFAULT_TIMEOUT = 30
    DEFAULT_RETRIES = 3
    DEFAULT_RETRY_DELAY = 5

    attr_reader :host, :port, :user, :options

    def initialize(host:, port: 22, user:, key_file: nil, password: nil, timeout: DEFAULT_TIMEOUT)
      @host = host
      @port = port
      @user = user
      @timeout = timeout
      @options = build_options(key_file: key_file, password: password, timeout: timeout)
    end

    # Wait for SSH to become available
    def wait_for_ssh(timeout: 1800, poll_interval: 10)
      deadline = Time.now + timeout
      attempt = 0

      while Time.now < deadline
        attempt += 1
        begin
          Timeout.timeout(10) do
            test_connection
            return true
          end
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
               Net::SSH::ConnectionTimeout, Net::SSH::Disconnect,
               Net::SSH::AuthenticationFailed, Timeout::Error, IOError => e
          remaining = (deadline - Time.now).to_i
          yield(attempt, remaining, e.message) if block_given?
          sleep(poll_interval) if Time.now < deadline
        end
      end

      false
    end

    # Execute a command and return result
    def execute(command, sudo: false)
      full_command = sudo ? "sudo #{command}" : command

      result = { stdout: String.new, stderr: String.new, exit_code: nil }

      Net::SSH.start(@host, @user, @options.merge(port: @port)) do |ssh|
        channel = ssh.open_channel do |ch|
          ch.exec(full_command) do |_ch, success|
            raise "Failed to execute command: #{command}" unless success

            ch.on_data { |_c, data| result[:stdout] << data }
            ch.on_extended_data { |_c, _type, data| result[:stderr] << data }
            ch.on_request('exit-status') { |_c, data| result[:exit_code] = data.read_long }
          end
        end
        channel.wait
      end

      result
    end

    # Execute with streaming output
    def execute_stream(command, sudo: false, &block)
      full_command = sudo ? "sudo #{command}" : command
      exit_code = nil

      Net::SSH.start(@host, @user, @options.merge(port: @port)) do |ssh|
        channel = ssh.open_channel do |ch|
          ch.exec(full_command) do |_ch, success|
            raise "Failed to execute command: #{command}" unless success

            ch.on_data { |_c, data| block.call(:stdout, data) }
            ch.on_extended_data { |_c, _type, data| block.call(:stderr, data) }
            ch.on_request('exit-status') { |_c, data| exit_code = data.read_long }
          end
        end
        channel.wait
      end

      exit_code
    end

    # Upload a file via SCP
    def upload(local_path, remote_path, sudo: false)
      if sudo
        # Upload to temp location, then move with sudo
        temp_path = "/tmp/#{File.basename(local_path)}.#{$$}"
        Net::SCP.upload!(@host, @user, local_path, temp_path, ssh: @options.merge(port: @port))
        execute("mv #{temp_path} #{remote_path}", sudo: true)
      else
        Net::SCP.upload!(@host, @user, local_path, remote_path, ssh: @options.merge(port: @port))
      end
    end

    # Upload content as a file
    def upload_content(content, remote_path, mode: '0644', sudo: false)
      require 'tempfile'

      Tempfile.create('pim-upload') do |f|
        f.write(content)
        f.close
        upload(f.path, remote_path, sudo: sudo)
        execute("chmod #{mode} #{remote_path}", sudo: sudo) if mode
      end
    end

    # Download a file via SCP
    def download(remote_path, local_path)
      Net::SCP.download!(@host, @user, remote_path, local_path, ssh: @options.merge(port: @port))
    end

    private

    def test_connection
      Net::SSH.start(@host, @user, @options.merge(port: @port, timeout: 5)) do |ssh|
        ssh.exec!('true')
      end
    end

    def build_options(key_file:, password:, timeout:)
      opts = {
        timeout: timeout,
        non_interactive: true,
        verify_host_key: :never
      }

      if key_file
        opts[:keys] = [File.expand_path(key_file)]
        opts[:keys_only] = true
      end

      opts[:password] = password if password

      opts
    end
  end

  # Execute SSH command via system ssh (fallback when net-ssh is unavailable)
  class SystemSSH
    def initialize(host:, port: 22, user:, key_file: nil)
      @host = host
      @port = port
      @user = user
      @key_file = key_file
    end

    def execute(command, sudo: false)
      ssh_cmd = build_ssh_command
      full_command = sudo ? "sudo #{command}" : command

      stdout, stderr, status = Open3.capture3("#{ssh_cmd} #{shell_escape(full_command)}")

      { stdout: stdout, stderr: stderr, exit_code: status.exitstatus }
    end

    def upload(local_path, remote_path)
      scp_cmd = build_scp_command
      system("#{scp_cmd} #{shell_escape(local_path)} #{@user}@#{@host}:#{shell_escape(remote_path)}")
    end

    private

    def build_ssh_command
      cmd = ['ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null']
      cmd += ['-p', @port.to_s] if @port != 22
      cmd += ['-i', @key_file] if @key_file
      cmd << "#{@user}@#{@host}"
      cmd.join(' ')
    end

    def build_scp_command
      cmd = ['scp', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null']
      cmd += ['-P', @port.to_s] if @port != 22
      cmd += ['-i', @key_file] if @key_file
      cmd.join(' ')
    end

    def shell_escape(str)
      Shellwords.escape(str)
    end
  end
end
