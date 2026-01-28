# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../id'

module Skills
  class Search
    class ClaudeCode
      PROMPT_TEMPLATE = <<~PROMPT
        Search the web for AI development skills, MCP servers, or Claude tools related to: %<query>s

        Find tools, libraries, and resources that can enhance AI-assisted development.
        Focus on MCP servers, Claude skills, and development tools.

        For each result found, provide the following in valid YAML format:
        - name: Human-readable name
        - description: One-line description of what it does
        - url: Source URL (GitHub, npm, etc.)
        - install_type: One of 'mcp', 'skill_folder', 'script'
        - install_cmd: Command to install (for mcp/script types, null for skill_folder)
        - source: Git clone URL (for skill_folder type only)
        - tags: List of relevant tags

        Return ONLY a valid YAML list of results, no other text.
        Maximum %<max>d results.

        Example format:
        ```yaml
        - name: Example MCP Server
          description: Does something useful
          url: https://github.com/example/mcp-server
          install_type: mcp
          install_cmd: "npx -y @example/mcp-server"
          tags:
            - example
            - mcp
        ```
      PROMPT

      def search(query, max_results: 10)
        prompt = format(PROMPT_TEMPLATE, query: query, max: max_results)

        stdout, stderr, status = Open3.capture3('claude', '-p', prompt)

        unless status.success?
          raise "Claude search failed: #{stderr}"
        end

        parse_results(stdout)
      end

      private

      def parse_results(output)
        yaml_content = extract_yaml(output)
        return {} if yaml_content.empty?

        results = YAML.safe_load(yaml_content, permitted_classes: [Symbol])
        return {} unless results.is_a?(Array)

        results.each_with_object({}) do |item, hash|
          next unless item.is_a?(Hash) && item['url']

          id = Id.generate(item['url'])
          hash[id] = item.merge('id' => id).transform_keys(&:to_s)
        end
      rescue Psych::SyntaxError => e
        warn "Warning: Failed to parse search results: #{e.message}"
        {}
      end

      def extract_yaml(output)
        if output.include?('```yaml')
          output.match(/```yaml\n?(.*?)```/m)&.[](1) || ''
        elsif output.include?('```')
          output.match(/```\n?(.*?)```/m)&.[](1) || ''
        else
          output.strip
        end
      end
    end
  end
end
