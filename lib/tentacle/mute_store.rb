# frozen_string_literal: true

require "json"
require "fileutils"

module Tentacle
  class MuteStore
    def initialize(app_name, path: nil)
      @app_name = app_name
      @custom_path = !path.nil?
      @path = path || default_path
    end

    def muted_groups
      data = read_data
      Array(data.dig("apps", @app_name, "muted_groups")).map(&:to_s).uniq
    end

    def mute(group)
      update_groups { |groups| groups << group.to_s unless groups.include?(group.to_s) }
    end

    def unmute(group)
      update_groups { |groups| groups.delete(group.to_s) }
    end

    private

    def default_path
      config_home = ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config"))
      File.join(config_home, "tentacle", "muted-groups.json")
    end

    def read_data
      return { "apps" => {} } unless File.file?(@path)

      JSON.parse(File.read(@path))
    rescue JSON::ParserError, Errno::ENOENT
      { "apps" => {} }
    end

    def update_groups
      data = read_data
      data["apps"] ||= {}
      data["apps"][@app_name] ||= {}
      groups = Array(data["apps"][@app_name]["muted_groups"]).map(&:to_s).uniq
      yield groups
      data["apps"][@app_name]["muted_groups"] = groups.sort

      directory = File.dirname(@path)
      FileUtils.mkdir_p(directory)
      FileUtils.chmod(0o700, directory) unless @custom_path

      temp_path = "#{@path}.tmp"
      File.open(temp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.pretty_generate(data) + "\n")
      end
      FileUtils.chmod(0o600, temp_path)
      File.rename(temp_path, @path)
      groups
    rescue SystemCallError
      groups || []
    end
  end
end
