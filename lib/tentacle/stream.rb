# frozen_string_literal: true

require "open3"
require "thread"

module Tentacle
  class LogLineMessage < Bubbletea::Message
    attr_reader :line

    def initialize(line)
      super()
      @line = line
    end
  end


  class StreamConnectedMessage < Bubbletea::Message
  end

  class StreamEndedMessage < Bubbletea::Message
    attr_reader :status, :reason

    def initialize(status: nil, reason: nil)
      super()
      @status = status
      @reason = reason
    end
  end

  class LogStream
    def initialize(app_name)
      @app_name = app_name
      @mutex = Mutex.new
      @started = false
      @closed = false
    end

    def next_message
      started_now = start_if_needed
      return StreamConnectedMessage.new if started_now
      return StreamEndedMessage.new(reason: "stream closed") if closed?

      line = @output.gets
      return LogLineMessage.new(line) if line

      status = @wait_thread&.value
      StreamEndedMessage.new(status: status&.exitstatus, reason: "Heroku log stream ended")
    rescue IOError => e
      StreamEndedMessage.new(reason: e.message)
    rescue Errno::ENOENT
      StreamEndedMessage.new(reason: "Could not find the `heroku` executable in PATH")
    rescue StandardError => e
      StreamEndedMessage.new(reason: "#{e.class}: #{e.message}")
    end

    def close
      @mutex.synchronize do
        @closed = true
        @output&.close unless @output&.closed?
        @stdin&.close unless @stdin&.closed?

        if @wait_thread&.alive?
          Process.kill("TERM", @wait_thread.pid)
        end
      rescue Errno::ESRCH, IOError
        nil
      end
    end

    def restart
      close
      @mutex.synchronize do
        @stdin = nil
        @output = nil
        @wait_thread = nil
        @started = false
        @closed = false
      end
    end

    private

    def closed?
      @mutex.synchronize { @closed }
    end

    def start_if_needed
      @mutex.synchronize do
        return false if @started

        @stdin, @output, @wait_thread = Open3.popen2e(
          "heroku", "logs", "--tail", "--app", @app_name
        )
        @stdin.close
        @started = true
        true
      end
    end
  end
end
