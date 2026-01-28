# frozen_string_literal: true

require 'fileutils'

module Skills
  class Installer
    class SkillFolder
      def initialize(config:)
        @config = config
      end

      def install(skill)
        source = skill['source']
        raise 'No source URL specified for skill_folder' unless source

        id = skill['id']
        install_path = File.join(@config.skills_dir, id)

        if Dir.exist?(install_path)
          puts "Skill folder already exists: #{install_path}"
          puts 'Updating...'
          update_repo(install_path)
        else
          clone_repo(source, install_path, skill['source_path'])
        end

        { success: true, install_path: install_path }
      end

      def uninstall(skill)
        id = skill['id']
        install_path = File.join(@config.skills_dir, id)

        if Dir.exist?(install_path)
          puts "Removing: #{install_path}"
          FileUtils.rm_rf(install_path)
          { success: true }
        else
          { success: true, message: 'Skill folder not found' }
        end
      end

      private

      def clone_repo(source, install_path, source_path = nil)
        FileUtils.mkdir_p(File.dirname(install_path))

        if source_path
          clone_subdirectory(source, install_path, source_path)
        else
          cmd = "git clone --depth 1 #{source} #{install_path}"
          puts "Running: #{cmd}"
          success = system(cmd)
          raise "Clone failed: #{source}" unless success
        end
      end

      def clone_subdirectory(source, install_path, source_path)
        require 'tmpdir'

        Dir.mktmpdir do |tmpdir|
          cmd = "git clone --depth 1 --filter=blob:none --sparse #{source} #{tmpdir}/repo"
          puts "Running: #{cmd}"
          success = system(cmd)
          raise "Clone failed: #{source}" unless success

          Dir.chdir("#{tmpdir}/repo") do
            system("git sparse-checkout set #{source_path}")
          end

          source_full_path = "#{tmpdir}/repo/#{source_path}"
          FileUtils.mkdir_p(install_path)
          FileUtils.cp_r("#{source_full_path}/.", install_path)
        end
      end

      def update_repo(install_path)
        Dir.chdir(install_path) do
          system('git pull --ff-only')
        end
      end
    end
  end
end
