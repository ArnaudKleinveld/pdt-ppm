# frozen_string_literal: true

module Skills
  class Installer
    class Script
      def install(skill)
        cmd = skill['install_cmd']
        raise 'No install_cmd specified for script skill' unless cmd

        puts "Running: #{cmd}"
        success = system(cmd)
        raise "Install script failed: #{cmd}" unless success

        { success: true }
      end

      def uninstall(skill)
        uninstall_cmd = skill['uninstall_cmd']

        if uninstall_cmd
          puts "Running: #{uninstall_cmd}"
          system(uninstall_cmd)
        else
          puts 'No uninstall command specified for this skill'
        end

        { success: true }
      end
    end
  end
end
