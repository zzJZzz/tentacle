# frozen_string_literal: true

require "open3"

module Tentacle
  class Preflight
    Result = Struct.new(:ok, :message, keyword_init: true) do
      def ok? = !!ok
    end

    AUTH_FAILURE = /not logged in|log in|login required|authentication|unauthorized|credentials?/i

    def initialize(runner: nil)
      @runner = runner || ->(*command) { Open3.capture3(*command) }
    end

    def check
      stdout, stderr, status = @runner.call("heroku", "auth:whoami")
      return Result.new(ok: true) if status.success?

      detail = [stderr, stdout].map { |value| value.to_s.strip }.reject(&:empty?).join(" ")

      if detail.match?(AUTH_FAILURE)
        Result.new(
          ok: false,
          message: <<~MESSAGE.strip
            Error: Heroku CLI authentication is required before Tentacle can start.

            Run:
              heroku login

            Then verify:
              heroku auth:whoami
          MESSAGE
        )
      else
        suffix = detail.empty? ? "" : "\n\nHeroku CLI response: #{detail}"
        Result.new(
          ok: false,
          message: <<~MESSAGE.strip + suffix
            Error: Tentacle could not verify Heroku CLI authentication.

            Verify the CLI yourself with:
              heroku auth:whoami
          MESSAGE
        )
      end
    rescue Errno::ENOENT
      Result.new(
        ok: false,
        message: <<~MESSAGE.strip
          Error: Heroku CLI was not found in PATH.

          Install the Heroku CLI, run `heroku login`, and then retry Tentacle.
        MESSAGE
      )
    rescue StandardError => error
      Result.new(
        ok: false,
        message: "Error: Tentacle could not run the Heroku CLI preflight: #{error.class}: #{error.message}"
      )
    end
  end
end
