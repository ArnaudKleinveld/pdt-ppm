# frozen_string_literal: true

module Skills
  class Search
    def initialize(config:)
      @config = config
      @provider = load_provider
    end

    def find(query, max_results: nil)
      max = max_results || @config.search_max_results
      @provider.search(query, max_results: max)
    end

    private

    def load_provider
      case @config.search_provider
      when 'claude_code'
        require_relative 'search/claude_code'
        Search::ClaudeCode.new
      when 'api'
        require_relative 'search/api'
        Search::Api.new(config: @config)
      else
        raise "Unknown search provider: #{@config.search_provider}"
      end
    end
  end
end
