# frozen_string_literal: true

require 'tty-prompt'
require 'tty-table'
require 'pastel'

module Skills
  class UI
    def initialize(config:)
      @config = config
      @prompt = TTY::Prompt.new
      @pastel = Pastel.new(enabled: config.colors?)
    end

    def select_skill(results, prompt_text: 'Select a skill:')
      return nil if results.empty?

      choices = results.map do |id, skill|
        name = skill['name'] || id
        desc = skill['description'] || ''
        { name: "#{name} - #{desc}", value: id }
      end

      @prompt.select(prompt_text, choices, per_page: 10)
    end

    def select_action(skill)
      choices = [
        { name: 'Install', value: :install },
        { name: 'Show details', value: :show },
        { name: 'Add to registry', value: :add },
        { name: 'Cancel', value: :cancel }
      ]

      @prompt.select("Action for #{skill['name']}:", choices)
    end

    def confirm(message)
      @prompt.yes?(message)
    end

    def skills_table(skills, source_label: nil)
      return puts 'No skills found.' if skills.empty?

      rows = skills.map do |id, skill|
        name = skill['name'] || id
        type = skill['install_type'] || '-'
        src = source_label || skill['source'] || '-'
        [id, name, type, src]
      end

      table = TTY::Table.new(
        header: %w[ID Name Type Source],
        rows: rows
      )

      puts table.render(:unicode, padding: [0, 1])
    end

    def skill_detail(skill)
      puts @pastel.bold(skill['name'] || skill['id'])
      puts @pastel.dim(skill['description']) if skill['description']
      puts
      puts "ID:           #{skill['id']}"
      puts "URL:          #{skill['url']}" if skill['url']
      puts "Install Type: #{skill['install_type']}" if skill['install_type']
      puts "Install Cmd:  #{skill['install_cmd']}" if skill['install_cmd']
      puts "Source:       #{skill['source']}" if skill['source']
      puts "Tags:         #{skill['tags']&.join(', ')}" if skill['tags']&.any?
      puts "Added:        #{skill['added_at']}" if skill['added_at']
      puts "Added By:     #{skill['added_by']}" if skill['added_by']
    end

    def state_table(installed)
      return puts 'No skills installed.' if installed.empty?

      rows = installed.map do |id, entry|
        source = entry['source'] || '-'
        installed_at = entry['installed_at']&.split('T')&.first || '-'
        [id, source, installed_at]
      end

      table = TTY::Table.new(
        header: ['ID', 'Source', 'Installed'],
        rows: rows
      )

      puts table.render(:unicode, padding: [0, 1])
    end

    def success(message)
      puts @pastel.green(message)
    end

    def error(message)
      puts @pastel.red(message)
    end

    def warn(message)
      puts @pastel.yellow(message)
    end

    def info(message)
      puts @pastel.cyan(message)
    end
  end
end
