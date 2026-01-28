# frozen_string_literal: true

require 'digest'

module Skills
  module Id
    def self.generate(url)
      normalized = url.to_s.downcase.gsub(%r{/$}, '')
      hash = Digest::SHA256.hexdigest(normalized)[0..7]
      slug = extract_slug(normalized)
      "#{slug}-#{hash}"
    end

    def self.extract_slug(url)
      url
        .gsub(%r{https?://}, '')
        .gsub(%r{github\.com/}, '')
        .gsub(%r{/tree/[^/]+/}, '-')
        .split('/')
        .reject(&:empty?)
        .last(2)
        .join('-')
        .gsub(/[^a-z0-9-]/, '')
        .slice(0, 30)
    end
  end
end
