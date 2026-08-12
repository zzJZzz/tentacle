# frozen_string_literal: true

require_relative "event"

module Tentacle
  class Parser
    LOG_LINE = /\A(?<timestamp>\S+)\s+(?<source>[^\[]+)\[(?<process>[^\]]+)\]:\s?(?<message>.*)\z/
    ERROR_PATTERN = /(?:\berror\b|exception|fatal|NoMethodError|ActiveRecord::|ActionController::|undefined method|\braised\b|\bfailed\b|permission denied)/i
    H_CODE_PATTERN = /\bcode=(H\d+)\b/i
    RUBY_EXCEPTION_PATTERN = /\b((?:[A-Z]\w*::)*[A-Z]\w*(?:Error|Exception|Timeout))\b/
    NAMESPACED_CLASS_PATTERN = /\b((?:[A-Z]\w*::)+[A-Z]\w+)\b/

    POSTGRES_SOURCE_PATTERN = /(?:postgres(?:ql)?|heroku-postgres|pgbouncer)/i
    POSTGRES_MESSAGE_PATTERN = /(?:\bPG::|\bPostgreSQL\b|\bpsql:\s|canceling statement due to statement timeout|remaining connection slots are reserved|server closed the connection unexpectedly|\bdeadlock detected\b)/i
    MYSQL_SOURCE_PATTERN = /(?:mysql|mariadb|cleardb|jawsdb|stackhero[-_]?mysql)/i
    MYSQL_MESSAGE_PATTERN = /(?:\bMysql2::|\bMySQL\b|\bMariaDB\b|MySQL server has gone away|Lock wait timeout exceeded|Deadlock found when trying to get lock|\bToo many connections\b)/i
    DATABASE_ERROR_PATTERN = /(?:\bPG::[A-Z]\w*|\bMysql2::[A-Z]\w*|canceling statement due to statement timeout|remaining connection slots are reserved|server closed the connection unexpectedly|MySQL server has gone away|Lock wait timeout exceeded|Deadlock found when trying to get lock|\bToo many connections\b)/i

    def parse(line)
      raw = line.to_s.chomp
      match = LOG_LINE.match(raw)

      unless match
        engine = database_engine_for(raw, nil, nil, raw)
        error = error_text?(raw)
        return Event.new(
          raw: raw,
          message: raw,
          category: :other,
          database_engine: engine,
          error: error,
          error_group: error ? error_group_for(raw, nil, engine) : nil
        )
      end

      source = match[:source]
      process = match[:process]
      message = match[:message]
      status = capture_integer(raw, /\bstatus=(\d{3})\b/)
      engine = database_engine_for(raw, source, process, message)
      error = error_event?(raw, status)

      Event.new(
        raw: raw,
        timestamp: match[:timestamp],
        source: source,
        process: process,
        message: message,
        category: category_for(source, process, message, engine),
        database_engine: engine,
        request_id: capture(raw, /\brequest_id=([^\s]+)/),
        status: status,
        method: capture(raw, /\bmethod=([A-Z]+)\b/),
        path: capture(raw, /\bpath="([^"]*)"/),
        service_ms: capture_integer(raw, /\bservice=(\d+)ms\b/),
        error: error,
        error_group: error ? error_group_for(raw, status, engine) : nil
      )
    end

    private

    def category_for(source, process, message = "", engine = nil)
      return :release if process == "api" && message.match?(/(?:\bDeploy\s+[0-9a-f]+\b|\bRelease\s+v\d+\s+created\b)/i)
      return :web if process.start_with?("web")
      return :worker if process.start_with?("worker")
      return :postgres if engine == :postgres && (process.match?(POSTGRES_SOURCE_PATTERN) || source.match?(POSTGRES_SOURCE_PATTERN))
      return :mysql if engine == :mysql && (process.match?(MYSQL_SOURCE_PATTERN) || source.match?(MYSQL_SOURCE_PATTERN))
      return :router if source == "heroku" && process == "router"
      return :heroku if source == "heroku"

      :other
    end

    def database_engine_for(raw, source, process, message)
      source_text = [source, process].compact.join(" ")
      return :postgres if source_text.match?(POSTGRES_SOURCE_PATTERN) || message.to_s.match?(POSTGRES_MESSAGE_PATTERN) || raw.match?(POSTGRES_MESSAGE_PATTERN)
      return :mysql if source_text.match?(MYSQL_SOURCE_PATTERN) || message.to_s.match?(MYSQL_MESSAGE_PATTERN) || raw.match?(MYSQL_MESSAGE_PATTERN)

      nil
    end

    def error_event?(raw, status)
      return true if status && status >= 500
      return true if H_CODE_PATTERN.match?(raw)

      error_text?(raw)
    end

    def error_text?(raw)
      ERROR_PATTERN.match?(raw) || DATABASE_ERROR_PATTERN.match?(raw)
    end

    def error_group_for(raw, status, database_engine = nil)
      if (h_code = capture(raw, H_CODE_PATTERN))
        return "Heroku #{h_code.upcase}"
      end

      if (exception = capture(raw, RUBY_EXCEPTION_PATTERN))
        return exception
      end

      if (namespaced = capture(raw, NAMESPACED_CLASS_PATTERN))
        return namespaced
      end

      if database_engine == :postgres && raw.match?(/\bFATAL:\s*/i)
        fatal = capture(raw, /\bFATAL:\s+(.+?)(?:\s+DETAIL:|\z)/i)
        return "Postgres: #{normalize_message(fatal)}" if fatal
      end

      if database_engine == :mysql && (mysql_error = capture(raw, /\bERROR\s+\d+\s*(?:\([^)]*\))?:?\s*(.+)\z/i))
        return "MySQL: #{normalize_message(mysql_error)}"
      end

      if (undefined_method = capture(raw, /(undefined method\s+[`'\"]?[^\s'\"`]+)/i))
        return normalize_message(undefined_method)
      end

      return "HTTP #{status}" if status && status >= 500

      if (generic = capture(raw, /\b(?:ERROR|EXCEPTION|FAILED|FAILURE):?\s+(.+)\z/i))
        prefix = case database_engine
        when :postgres then "Postgres: "
        when :mysql then "MySQL: "
        else ""
        end
        return "#{prefix}#{normalize_message(generic)}"
      end

      "Other error"
    end

    def normalize_message(message)
      message.to_s
             .strip
             .gsub(/\s+/, " ")
             .gsub(/\brequest_id=[^\s]+/, "request_id=…")
             .slice(0, 90)
    end

    def capture(text, regexp)
      regexp.match(text)&.[](1)
    end

    def capture_integer(text, regexp)
      value = capture(text, regexp)
      value&.to_i
    end
  end
end
