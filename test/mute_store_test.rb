# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/tentacle/mute_store"

class MuteStoreTest < Minitest::Test
  def test_persists_groups_per_app
    Dir.mktmpdir do |dir|
      path = File.join(dir, "muted.json")
      store = Tentacle::MuteStore.new("app-a", path: path)
      store.mute("NoMethodError")
      store.mute("Heroku H12")

      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal ["Heroku H12", "NoMethodError"], Tentacle::MuteStore.new("app-a", path: path).muted_groups.sort
      assert_equal [], Tentacle::MuteStore.new("app-b", path: path).muted_groups

      store.unmute("NoMethodError")
      assert_equal ["Heroku H12"], Tentacle::MuteStore.new("app-a", path: path).muted_groups
    end
  end
end
