# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/tentacle/preflight"

class PreflightTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def runner(stdout: "", stderr: "", success: true)
    ->(*_command) { [stdout, stderr, FakeStatus.new(success)] }
  end

  def test_authenticated_heroku_cli_passes
    result = Tentacle::Preflight.new(
      runner: runner(stdout: "user@example.com\n", success: true)
    ).check

    assert result.ok?
    assert_nil result.message
  end

  def test_logged_out_cli_returns_tentacle_login_guidance
    result = Tentacle::Preflight.new(
      runner: runner(stderr: "Error: not logged in", success: false)
    ).check

    refute result.ok?
    assert_includes result.message, "Heroku CLI authentication is required"
    assert_includes result.message, "heroku login"
    assert_includes result.message, "heroku auth:whoami"
  end

  def test_non_auth_cli_failure_is_not_mislabeled_as_logged_out
    result = Tentacle::Preflight.new(
      runner: runner(stderr: "network timeout", success: false)
    ).check

    refute result.ok?
    assert_includes result.message, "could not verify Heroku CLI authentication"
    assert_includes result.message, "network timeout"
  end

  def test_missing_heroku_cli_has_clear_message
    missing = ->(*_command) { raise Errno::ENOENT, "heroku" }
    result = Tentacle::Preflight.new(runner: missing).check

    refute result.ok?
    assert_includes result.message, "Heroku CLI was not found in PATH"
  end
end
