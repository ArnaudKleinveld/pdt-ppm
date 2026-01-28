# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'digest'
require 'time'

module PimRegistry
  # Image registry for tracking built images
  # Registry is stored alongside images in image_dir/registry.yml
  class Registry
    attr_reader :registry_path

    def initialize(image_dir:)
      @image_dir = File.expand_path(image_dir)
      @registry_path = File.join(@image_dir, 'registry.yml')
      @data = load_registry
    end

    # List all registered images
    def images
      @data['images'] || {}
    end

    # Get image by profile and architecture
    def find(profile:, arch:)
      key = image_key(profile, arch)
      images[key]
    end

    # Get the latest image for a profile/arch combination
    def latest(profile:, arch:)
      key = image_key(profile, arch)
      entry = images[key]
      return nil unless entry

      entry.merge('key' => key)
    end

    # Register a new image
    def register(profile:, arch:, path:, iso:, cache_key:, build_time: nil, metadata: {})
      key = image_key(profile, arch)
      build_time ||= Time.now.utc.iso8601

      entry = {
        'profile' => profile,
        'arch' => arch,
        'path' => path,
        'filename' => File.basename(path),
        'iso' => iso,
        'cache_key' => cache_key,
        'build_time' => build_time,
        'size' => File.exist?(path) ? File.size(path) : nil
      }.merge(metadata)

      @data['images'] ||= {}
      @data['images'][key] = entry

      save_registry
      entry
    end

    # Remove an image from registry
    def unregister(profile:, arch:)
      key = image_key(profile, arch)
      entry = images.delete(key)
      save_registry if entry
      entry
    end

    # Check if an image exists with matching cache key
    def cached?(profile:, arch:, cache_key:)
      entry = find(profile: profile, arch: arch)
      return false unless entry
      return false unless entry['cache_key'] == cache_key
      return false unless entry['path'] && File.exist?(entry['path'])

      true
    end

    # List images as formatted output
    def list(long: false)
      return [] if images.empty?

      entries = images.map do |key, entry|
        {
          key: key,
          profile: entry['profile'],
          arch: entry['arch'],
          filename: entry['filename'],
          build_time: entry['build_time'],
          size: entry['size'],
          path: entry['path'],
          exists: entry['path'] && File.exist?(entry['path'])
        }
      end

      entries.sort_by { |e| e[:build_time] || '' }.reverse
    end

    # Clean orphaned entries (images that no longer exist on disk)
    def clean_orphaned
      removed = []
      images.each do |key, entry|
        unless entry['path'] && File.exist?(entry['path'])
          removed << key
        end
      end

      removed.each { |key| images.delete(key) }
      save_registry unless removed.empty?
      removed
    end

    # Get deployment history for an image
    def deployments(profile:, arch:)
      entry = find(profile: profile, arch: arch)
      return [] unless entry

      entry['deployments'] || []
    end

    # Record a deployment
    def record_deployment(profile:, arch:, target:, target_type:, deployed_at: nil, metadata: {})
      key = image_key(profile, arch)
      entry = images[key]
      return nil unless entry

      deployed_at ||= Time.now.utc.iso8601

      deployment = {
        'target' => target,
        'target_type' => target_type,
        'deployed_at' => deployed_at
      }.merge(metadata)

      entry['deployments'] ||= []
      entry['deployments'] << deployment

      save_registry
      deployment
    end

    private

    def image_key(profile, arch)
      "#{profile}-#{arch}"
    end

    def load_registry
      return default_registry unless File.exist?(@registry_path)

      data = YAML.load_file(@registry_path)
      return default_registry unless data.is_a?(Hash)

      data
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse registry: #{e.message}"
      default_registry
    end

    def save_registry
      FileUtils.mkdir_p(@image_dir)
      File.write(@registry_path, YAML.dump(@data))
    end

    def default_registry
      {
        'version' => 1,
        'images' => {}
      }
    end
  end
end
