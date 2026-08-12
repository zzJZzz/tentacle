# frozen_string_literal: true

require "bubbletea"
require "json"
require "open3"
require "time"

module Tentacle
  Release = Struct.new(
    :version,
    :description,
    :status,
    :created_at,
    :current,
    keyword_init: true
  ) do
    def deploy?
      description.to_s.start_with?("Deploy ")
    end

    def version_label
      "v#{version}"
    end

    def time
      return nil if created_at.to_s.empty?

      Time.iso8601(created_at)
    rescue ArgumentError
      nil
    end
  end

  class ReleaseHistoryMessage < Bubbletea::Message
    attr_reader :releases, :error

    def initialize(releases:, error: nil)
      super()
      @releases = releases
      @error = error
    end
  end

  class ReleaseHistory
    def initialize(app_name, limit: 20)
      @app_name = app_name
      @limit = limit
    end

    def fetch_message
      stdout, stderr, status = Open3.capture3(
        "heroku", "releases", "--json", "-n", @limit.to_s, "--app", @app_name
      )

      unless status.success?
        reason = stderr.to_s.strip
        reason = "heroku releases exited #{status.exitstatus}" if reason.empty?
        return ReleaseHistoryMessage.new(releases: [], error: reason)
      end

      releases = JSON.parse(stdout).filter_map { |row| parse_release(row) }
      releases.sort_by! { |release| release.time || Time.at(0) }
      ReleaseHistoryMessage.new(releases: releases)
    rescue Errno::ENOENT
      ReleaseHistoryMessage.new(releases: [], error: "Could not find the `heroku` executable in PATH")
    rescue JSON::ParserError => error
      ReleaseHistoryMessage.new(releases: [], error: "Could not parse release history: #{error.message}")
    rescue StandardError => error
      ReleaseHistoryMessage.new(releases: [], error: "#{error.class}: #{error.message}")
    end

    private

    def parse_release(row)
      version = row["version"]
      return nil unless version

      Release.new(
        version: version.to_i,
        description: row["description"].to_s,
        status: row["status"].to_s,
        created_at: row["created_at"] || row["updated_at"],
        current: !!row["current"]
      )
    end
  end
end
