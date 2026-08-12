# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/tentacle/parser"

class ParserTest < Minitest::Test
  def setup
    @parser = Tentacle::Parser.new
  end

  def test_parses_web_request_and_groups_http_500
    event = @parser.parse('2026-08-11T18:35:03.013675+00:00 app[web.1]: request_id=abc123 method=GET path="/products/foo" status=500 service=1661ms')

    assert event.web?
    assert event.error?
    assert_equal "abc123", event.request_id
    assert_equal 500, event.status
    assert_equal "GET", event.method
    assert_equal "/products/foo", event.path
    assert_equal 1661, event.service_ms
    assert_equal "HTTP 500", event.error_group
  end

  def test_groups_postgres_fatal_message
    event = @parser.parse('2026-08-11T18:42:49.000000+00:00 app[postgres.1]: FATAL: permission denied for database "postgres"')

    assert event.postgres?
    assert event.error?
    assert_equal 'Postgres: permission denied for database "postgres"', event.error_group
  end

  def test_groups_router_h_code_before_http_status
    event = @parser.parse('2026-08-11T18:35:05.075156+00:00 heroku[router]: at=error code=H12 method=GET path="/" status=503 service=30000ms')

    assert event.heroku?
    assert event.error?
    assert_equal :router, event.category
    assert_equal "Heroku H12", event.error_group
  end

  def test_groups_ruby_exception_class
    event = @parser.parse('2026-08-11T18:35:05.075156+00:00 app[web.2]: NoMethodError: undefined method `price` for nil')

    assert event.error?
    assert_equal "NoMethodError", event.error_group
  end

  def test_groups_namespaced_rails_exception
    event = @parser.parse('2026-08-11T18:35:05.075156+00:00 app[web.2]: ActionController::InvalidAuthenticityToken')

    assert event.error?
    assert_equal "ActionController::InvalidAuthenticityToken", event.error_group
  end

  def test_marks_live_api_deploy_lines_as_release_events
    event = @parser.parse('2026-08-11T18:30:00Z app[api]: Deploy abc1234 by user dev@example.com')

    assert event.release?
    assert_equal :release, event.category
    refute event.error?
  end

  def test_web_postgres_error_keeps_web_category_and_is_database_related
    event = @parser.parse('2026-08-11T18:42:49Z app[web.1]: PG::ConnectionBad: server closed the connection unexpectedly')

    assert event.web?
    assert event.database?
    assert event.postgres?
    assert_equal :web, event.category
    assert_equal "PG", event.database_label
    assert_equal "PG::ConnectionBad", event.error_group
  end

  def test_worker_mysql_error_keeps_worker_category_and_is_database_related
    event = @parser.parse('2026-08-11T18:42:50Z app[worker.1]: Mysql2::Error: Lock wait timeout exceeded; try restarting transaction')

    assert event.worker?
    assert event.database?
    assert event.mysql?
    assert_equal :worker, event.category
    assert_equal "MYSQL", event.database_label
    assert_equal "Mysql2::Error", event.error_group
  end

  def test_native_mysql_line_is_classified_and_grouped
    event = @parser.parse('2026-08-11T18:42:51Z app[mysql.1]: ERROR 1040 (HY000): Too many connections')

    assert event.database?
    assert event.mysql?
    assert_equal :mysql, event.category
    assert event.error?
    assert_equal "MySQL: Too many connections", event.error_group
  end

  def test_normal_application_line_is_not_database_related
    event = @parser.parse('2026-08-11T18:42:52Z app[web.1]: Completed 200 OK')

    assert event.web?
    refute event.database?
    refute event.postgres?
    refute event.mysql?
  end

end