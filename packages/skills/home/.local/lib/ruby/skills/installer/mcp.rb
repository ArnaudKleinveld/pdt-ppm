# frozen_string_literal: true

module Skills
  class Installer
    class Mcp
      def install(skill)
        cmd = skill['install_cmd']
        raise 'No install_cmd specified for MCP skill' unless cmd

        puts "Running: #{cmd}"
        success = system(cmd)
        raise "Install failed: #{cmd}" unless success

        { success: true }
      end

      def uninstall(skill)
        name = extract_mcp_name(skill)
        return { success: true, message: 'No MCP name to remove' } unless name

        cmd = "claude mcp remove #{name}"
        puts "Running: #{cmd}"
        system(cmd)
        { success: true }
      end

      private

      def extract_mcp_name(skill)
        cmd = skill['install_cmd']
        return nil unless cmd

        if cmd.include?('mcp add')
          cmd.match(/mcp add\s+(\S+)/)&.[](1)
        else
          nil
        end
      end
    end
  end
end
