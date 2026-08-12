# frozen_string_literal: true

module Tentacle
  Event = Struct.new(
    :raw,
    :timestamp,
    :source,
    :process,
    :message,
    :category,
    :database_engine,
    :request_id,
    :status,
    :method,
    :path,
    :service_ms,
    :error,
    :error_group,
    keyword_init: true
  ) do
    def error?
      !!error
    end

    def web?
      category == :web
    end

    def worker?
      category == :worker
    end

    def database?
      !database_engine.nil?
    end

    def postgres?
      database_engine == :postgres
    end

    def mysql?
      database_engine == :mysql
    end

    def database_label
      case database_engine
      when :postgres then "PG"
      when :mysql then "MYSQL"
      end
    end

    def release?
      category == :release
    end

    def incident?
      category == :incident
    end

    def heroku?
      source == "heroku"
    end

    def time_label
      return "--:--:--" unless timestamp

      match = timestamp.match(/T(\d{2}:\d{2}:\d{2})/)
      match ? match[1] : timestamp[0, 8]
    end

    def source_label
      case category
      when :web then "WEB"
      when :worker then "WORK"
      when :postgres then "PG"
      when :mysql then "MYSQL"
      when :router then "ROUTER"
      when :heroku then "HEROKU"
      when :release then "RELEASE"
      when :incident then "SESSION"
      else "OTHER"
      end
    end
  end
end
