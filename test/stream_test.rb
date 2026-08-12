# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "bubbletea"
require_relative "../lib/tentacle/stream"

class StreamTest < Minitest::Test
  FakeStatus = Struct.new(:exitstatus)
  FakeWaitThread = Struct.new(:value, :pid) do
    def alive? = false
  end

  def test_first_read_reports_connection_before_waiting_for_a_log_line
    stdin = StringIO.new
    output = StringIO.new("2026-08-12T15:00:00Z app[web.1]: booted\n")
    wait_thread = FakeWaitThread.new(FakeStatus.new(0), 123)
    stream = Tentacle::LogStream.new("test-app")

    Open3.stub(:popen2e, [stdin, output, wait_thread]) do
      connected = stream.next_message
      line = stream.next_message

      assert_instance_of Tentacle::StreamConnectedMessage, connected
      assert_instance_of Tentacle::LogLineMessage, line
      assert_includes line.line, "booted"
    end
  end
end
