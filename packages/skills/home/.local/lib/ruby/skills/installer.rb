# frozen_string_literal: true

module Skills
  class Installer
    def initialize(config:, state:)
      @config = config
      @state = state
    end

    def install(skill, source:)
      skill = skill.transform_keys(&:to_s)
      install_type = skill['install_type']

      installer = case install_type
                  when 'mcp'
                    require_relative 'installer/mcp'
                    Installer::Mcp.new
                  when 'skill_folder'
                    require_relative 'installer/skill_folder'
                    Installer::SkillFolder.new(config: @config)
                  when 'script'
                    require_relative 'installer/script'
                    Installer::Script.new
                  else
                    raise "Unknown install type: #{install_type}"
                  end

      result = installer.install(skill)
      @state.mark_installed(skill['id'], source: source, install_path: result[:install_path])
      result
    end

    def uninstall(skill)
      skill = skill.transform_keys(&:to_s)
      install_type = skill['install_type']

      installer = case install_type
                  when 'mcp'
                    require_relative 'installer/mcp'
                    Installer::Mcp.new
                  when 'skill_folder'
                    require_relative 'installer/skill_folder'
                    Installer::SkillFolder.new(config: @config)
                  when 'script'
                    require_relative 'installer/script'
                    Installer::Script.new
                  else
                    raise "Unknown install type: #{install_type}"
                  end

      installer.uninstall(skill)
      @state.mark_uninstalled(skill['id'])
    end
  end
end
