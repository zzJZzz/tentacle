# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/tentacle/release_history"

class ReleaseHistoryTest < Minitest::Test
  def test_parses_release_json_shape
    history = Tentacle::ReleaseHistory.new("test-app")
    release = history.send(:parse_release, {
      "version" => 52,
      "description" => "Deploy b41eb7c",
      "status" => "success",
      "created_at" => "2026-08-11T18:30:00Z",
      "current" => true,
      "user" => { "email" => "dev@example.com" }
    })

    assert_equal 52, release.version
    assert_equal "v52", release.version_label
    assert release.deploy?
    assert_equal "success", release.status
    assert release.current
  end
end
