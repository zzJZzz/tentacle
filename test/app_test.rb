# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/tentacle/app"

class AppTest < Minitest::Test
  class FakeMuteStore
    attr_reader :groups

    def initialize(groups = [])
      @groups = groups.dup
    end

    def muted_groups = @groups.dup
    def mute(group) = (@groups << group unless @groups.include?(group))
    def unmute(group) = @groups.delete(group)
  end

  def setup
    @mute_store = FakeMuteStore.new
    @app = Tentacle::App.new(app_name: "test-app", color: false, mute_store: @mute_store)
    @app.update(Bubbletea::WindowSizeMessage.new(width: 120, height: 30))
  end

  def key(name)
    Bubbletea::KeyMessage.new(name)
  end

  def add(line)
    @app.update(Tentacle::LogLineMessage.new(line))
  end

  def tabs_line(app = @app)
    app.view.split("\n").find { |line| line.include?("1:Overview") }
  end

  def test_search_buffer_accepts_typing_without_frozen_string_error
    @app.update(key("/"))
    @app.update(key("e"))
    @app.update(key("r"))
    @app.update(key("r"))

    assert_equal "err", @app.instance_variable_get(:@search)
    assert @app.instance_variable_get(:@search_mode)
    assert_includes @app.view, "err▌"

    @app.update(key("enter"))
    refute @app.instance_variable_get(:@search_mode)
    assert_equal "err", @app.instance_variable_get(:@search)
  end

  def test_escape_restores_previous_search
    @app.update(key("/"))
    @app.update(key("a"))
    @app.update(key("enter"))
    assert_equal "a", @app.instance_variable_get(:@search)

    @app.update(key("/"))
    @app.update(key("b"))
    assert_equal "ab", @app.instance_variable_get(:@search)
    @app.update(key("esc"))

    assert_equal "a", @app.instance_variable_get(:@search)
  end

  def test_keyboard_selection_is_visibly_marked_and_moves
    add('2026-08-11T18:35:01Z app[web.1]: first line')
    add('2026-08-11T18:35:02Z app[web.1]: second line')
    add('2026-08-11T18:35:03Z app[web.1]: third line')
    @app.update(key("3"))

    assert_includes @app.view, "▶ 18:35:03 WEB"
    assert_includes @app.view, "selected 3/3 · FOLLOW"

    @app.update(key("up"))
    view = @app.view
    assert_includes view, "▶ 18:35:02 WEB"
    assert_includes view, "selected 2/3"
    refute_includes view, "selected 2/3 · FOLLOW"
  end

  def test_enter_opens_detail_with_buffered_context
    add('2026-08-11T18:35:01Z app[web.1]: before one')
    add('2026-08-11T18:35:02Z app[web.1]: before two')
    add('2026-08-11T18:35:03Z app[web.1]: selected event')
    add('2026-08-11T18:35:04Z app[web.1]: after one')
    @app.update(key("3"))
    @app.update(key("up"))
    @app.update(key("enter"))

    view = @app.view
    assert_includes view, "Event detail"
    assert_includes view, "Buffered context (±3 lines)"
    assert_includes view, "before two"
    assert_includes view, "selected event"
    assert_includes view, "after one"
  end

  def test_n_and_shift_n_jump_between_errors
    add('2026-08-11T18:35:01Z app[web.1]: normal')
    add('2026-08-11T18:35:02Z app[web.1]: NoMethodError: first failure')
    add('2026-08-11T18:35:03Z app[web.1]: normal again')
    add('2026-08-11T18:35:04Z app[web.1]: ActiveRecord::RecordNotFound: second failure')
    @app.update(key("3"))
    @app.update(key("g"))

    @app.update(key("n"))
    assert_includes @app.view, "▶ 18:35:02 WEB"

    @app.update(key("n"))
    assert_includes @app.view, "▶ 18:35:04 WEB"

    @app.update(key("N"))
    assert_includes @app.view, "▶ 18:35:02 WEB"
  end

  def test_slow_tab_filters_by_service_time
    add('2026-08-11T18:35:03Z heroku[router]: method=GET path="/slow" status=200 service=1450ms request_id=slow1')
    add('2026-08-11T18:35:04Z heroku[router]: method=GET path="/fast" status=200 service=50ms request_id=fast1')
    @app.update(key("6"))

    view = @app.view
    assert_includes view, "/slow"
    refute_includes view, "/fast"
  end

  def test_tab_counts_stay_attached_to_their_own_tab_label
    add('2026-08-11T18:35:02Z app[web.1]: NoMethodError: first failure')
    add('2026-08-11T18:35:03Z app[web.1]: NoMethodError: first failure')

    tabs = tabs_line

    assert_includes tabs, "4:Errors·2"
    assert_includes tabs, "5:Groups·1"
    refute_includes tabs, "4:Errors 2"
  end

  def test_tab_counts_render_in_their_own_style
    marker = Class.new do
      def method_missing(_name, *_args) = self
      def respond_to_missing?(_name, _include_private = false) = true
      def render(text) = "<count>#{text}</count>"
    end.new

    app = Tentacle::App.new(app_name: "test-app", color: true, mute_store: FakeMuteStore.new)
    app.update(Bubbletea::WindowSizeMessage.new(width: 120, height: 30))
    styles = app.instance_variable_get(:@styles)
    styles[:tab_inactive_count] = marker
    styles[:tab_active_count] = marker
    app.update(Tentacle::LogLineMessage.new('2026-08-11T18:35:02Z app[web.1]: NoMethodError: boom'))

    tabs = tabs_line(app)

    assert_includes tabs, "4:Errors<count>·1</count>"
    assert_includes tabs, "7:Worker"
    refute_includes tabs, "7:Worker<count>"
  end

  def test_tab_counts_are_hidden_in_narrow_terminals
    add('2026-08-11T18:35:02Z app[web.1]: NoMethodError: first failure')
    @app.update(Bubbletea::WindowSizeMessage.new(width: 100, height: 30))

    tabs = tabs_line

    assert_includes tabs, "4:Errors"
    refute_includes tabs, "4:Errors·"
  end

  def test_each_tab_has_description_above_search_line
    @app.update(key("3"))
    lines = @app.view.split("\n")

    assert_includes lines[2], "Rails web dyno activity"
    assert_includes lines[3], "search current view"
  end

  def test_overview_renders_ntcharts_metrics
    add('2026-08-11T18:35:03Z heroku[router]: method=GET path="/ok" status=200 service=145ms request_id=a')
    add('2026-08-11T18:35:04Z heroku[router]: method=GET path="/bad" status=500 service=1200ms request_id=b')

    view = @app.view
    assert_includes view, "Requests / min"
    assert_includes view, "Errors / min"
    assert_includes view, "Slow / min"
    assert_includes view, "Recurring errors"
  end

  def test_muting_group_hides_it_from_error_views_but_keeps_raw_event
    add('2026-08-11T18:35:02Z app[web.1]: NoMethodError: first failure')
    add('2026-08-11T18:35:03Z app[web.1]: normal')

    @app.update(key("5"))
    assert_includes @app.view, "NoMethodError"
    @app.update(key("m"))
    assert_includes @app.view, "No matching error groups yet."
    assert_includes @mute_store.groups, "NoMethodError"

    @app.update(key("4"))
    assert_includes @app.view, "no matching lines"

    @app.update(key("3"))
    assert_includes @app.view, "NoMethodError"

    @app.update(key("5"))
    @app.update(key("M"))
    assert_includes @app.view, "NoMethodError"
    assert_includes @app.view, "[MUTED]"
    @app.update(key("m"))
    refute_includes @mute_store.groups, "NoMethodError"
  end

  def test_release_context_shows_release_before_selected_event
    release = Tentacle::Release.new(
      version: 42,
      description: "Deploy abc1234",
      status: "success",
      created_at: "2026-08-11T18:30:00Z",
      current: true
    )
    @app.update(Tentacle::ReleaseHistoryMessage.new(releases: [release]))
    add('2026-08-11T18:35:03Z app[web.1]: NoMethodError: boom')
    @app.update(key("3"))

    view = @app.view
    assert_includes view, "v42 Deploy abc1234"
    assert_includes view, "selected +5m"

    @app.update(key("enter"))
    detail = @app.view
    assert_includes detail, "Prior release"
    assert_includes detail, "v42 · Deploy abc1234"
    assert_includes detail, "After release"
    assert_includes detail, "5m"
  end


  def test_incident_session_marks_boundary_and_can_scope_views
    now = Time.utc(2026, 8, 11, 20, 22, 0)
    app = Tentacle::App.new(
      app_name: "test-app",
      color: false,
      mute_store: FakeMuteStore.new,
      clock: -> { now }
    )
    app.update(Bubbletea::WindowSizeMessage.new(width: 120, height: 30))

    app.update(Tentacle::LogLineMessage.new('2026-08-11T20:21:50Z app[web.1]: NoMethodError: old failure'))
    app.update(key("s"))
    app.update(Tentacle::LogLineMessage.new('2026-08-11T20:22:01Z app[web.1]: ActiveRecord::RecordNotFound: repro failure'))

    app.update(key("2"))
    assert_includes app.view, "INCIDENT STARTED"
    assert_includes app.view, "old failure"
    assert_includes app.view, "repro failure"

    app.update(key("i"))
    view = app.view
    assert_includes view, "INCIDENT-ONLY ON"
    refute_includes view, "old failure"
    assert_includes view, "repro failure"
  end

  def test_stopped_incident_excludes_later_events_from_incident_only_scope
    times = [Time.utc(2026, 8, 11, 20, 22, 0), Time.utc(2026, 8, 11, 20, 24, 0)]
    app = Tentacle::App.new(
      app_name: "test-app",
      color: false,
      mute_store: FakeMuteStore.new,
      clock: -> { times.shift || Time.utc(2026, 8, 11, 20, 24, 0) }
    )
    app.update(Bubbletea::WindowSizeMessage.new(width: 120, height: 30))

    app.update(key("s"))
    app.update(Tentacle::LogLineMessage.new('2026-08-11T20:23:00Z app[web.1]: NoMethodError: inside incident'))
    app.update(key("s"))
    app.update(Tentacle::LogLineMessage.new('2026-08-11T20:25:00Z app[web.1]: NoMethodError: after incident'))
    app.update(key("i"))
    app.update(key("2"))

    view = app.view
    assert_includes view, "INCIDENT STARTED"
    assert_includes view, "INCIDENT ENDED"
    assert_includes view, "inside incident"
    refute_includes view, "after incident"
  end

  def test_incident_only_groups_count_only_reproduction_errors
    now = Time.utc(2026, 8, 11, 20, 22, 0)
    app = Tentacle::App.new(
      app_name: "test-app",
      color: false,
      mute_store: FakeMuteStore.new,
      clock: -> { now }
    )
    app.update(Bubbletea::WindowSizeMessage.new(width: 120, height: 30))

    app.update(Tentacle::LogLineMessage.new('2026-08-11T20:21:50Z app[web.1]: NoMethodError: old failure'))
    app.update(key("s"))
    2.times do |index|
      app.update(Tentacle::LogLineMessage.new("2026-08-11T20:22:0#{index + 1}Z app[web.1]: ActiveRecord::RecordNotFound: repro #{index}"))
    end
    app.update(key("i"))
    app.update(key("5"))

    view = app.view
    refute_includes view, "NoMethodError"
    assert_includes view, "ActiveRecord::RecordNotFound"
    assert_match(/\b2\s+ActiveRecord::RecordNotFound/, view)
  end


  def test_copy_for_llm_builds_redacted_diagnostic_context
    copied = nil
    app = Tentacle::App.new(
      app_name: "customer-app",
      color: false,
      mute_store: FakeMuteStore.new,
      clipboard_writer: ->(text) { copied = text }
    )
    app.update(Bubbletea::WindowSizeMessage.new(width: 140, height: 30))
    app.update(Tentacle::LogLineMessage.new(
      '2026-08-11T18:35:03Z app[web.1]: RuntimeError: failed token=super-secret password=hunter2 api_key="quoted secret" Authorization=Bearer abc.def.ghi email=customer@example.com url=https://user:pass@example.com/path'
    ))
    app.update(key("4"))
    app.update(key("L"))

    refute_nil copied
    assert_includes copied, "TENTACLE DIAGNOSTIC CONTEXT"
    assert_includes copied, "App: [REDACTED APP]"
    refute_includes copied, "customer-app"
    assert_includes copied, "View: Errors"
    assert_includes copied, "REQUEST TO THE LLM"
    assert_includes copied, "token=[REDACTED]"
    assert_includes copied, "password=[REDACTED]"
    refute_includes copied, "super-secret"
    refute_includes copied, "hunter2"
    refute_includes copied, "abc.def.ghi"
    refute_includes copied, "quoted secret"
    refute_includes copied, "user:pass@example.com"
    refute_includes copied, "customer@example.com"
    assert_includes copied, "[REDACTED_EMAIL]"
    assert_includes app.view, "copied redacted LLM context"
  end

  def test_dual_screen_shows_normal_ui_and_llm_preview
    add('2026-08-11T18:35:03Z app[web.1]: NoMethodError: boom')
    @app.update(Bubbletea::WindowSizeMessage.new(width: 140, height: 30))
    @app.update(key("3"))
    @app.update(key("d"))

    view = @app.view
    assert @app.instance_variable_get(:@dual_screen)
    assert_includes view, "TENTACLE"
    assert_includes view, "LLM COPY PREVIEW"
    assert_includes view, "TENTACLE DIAGNOSTIC CONTEXT"
    assert_includes view, "App: [REDACTED APP]"
    refute_includes view, "App: test-app"
    assert_operator view.lines.map { |line| line.chomp.length }.max, :<=, 140
  end

  def test_dual_screen_requires_wide_terminal
    @app.update(Bubbletea::WindowSizeMessage.new(width: 100, height: 30))
    @app.update(key("d"))

    refute @app.instance_variable_get(:@dual_screen)
    assert_equal "dual screen needs at least 120 columns", @app.instance_variable_get(:@clipboard_notice)
  end

  def test_database_tab_keeps_log_list_shape_and_adds_engine_identifier
    add('2026-08-11T18:35:01Z app[web.1]: PG::QueryCanceled: canceling statement due to statement timeout')
    add('2026-08-11T18:35:02Z app[worker.1]: Mysql2::Error: Lock wait timeout exceeded; try restarting transaction')
    add('2026-08-11T18:35:03Z app[web.1]: normal application line')

    @app.update(key("9"))
    view = @app.view

    assert_includes view, "9:Database"
    assert_includes view, "Database-related output, including connection failures, query errors, and database-side diagnostics."
    assert_includes view, "WEB    [PG]"
    assert_includes view, "WORK   [MYSQL]"
    assert_includes view, "PG::QueryCanceled"
    assert_includes view, "Mysql2::Error"
    refute_includes view, "normal application line"
  end

  def test_database_error_still_appears_in_original_source_tab
    add('2026-08-11T18:35:01Z app[web.1]: PG::ConnectionBad: server closed the connection unexpectedly')

    @app.update(key("3"))
    web_view = @app.view
    assert_includes web_view, "WEB"
    assert_includes web_view, "PG::ConnectionBad"
    refute_includes web_view, "[PG]"

    @app.update(key("9"))
    database_view = @app.view
    assert_includes database_view, "WEB    [PG]"
  end

  def test_database_tab_has_clear_empty_state_for_apps_without_database_logs
    add('2026-08-11T18:35:03Z app[web.1]: normal application line')
    @app.update(key("9"))

    assert_includes @app.view, "No database-related log lines detected."
  end

  def test_help_uses_database_name
    @app.update(key("?"))

    assert_includes @app.view, "9 Database"
    refute_includes @app.view, "9 Postgres"
  end

  def test_init_batches_release_log_and_spinner_commands
    _model, command = @app.init

    assert_instance_of Bubbletea::BatchCommand, command
    assert_equal 3, command.commands.length
  end

  def test_release_history_message_does_not_start_a_second_log_read
    _model, command = @app.update(Tentacle::ReleaseHistoryMessage.new(releases: []))

    assert_nil command
  end

  def test_header_transitions_from_connecting_to_live_when_stream_is_connected
    assert_includes @app.view, "CONNECTING"

    @app.update(Tentacle::ReleaseHistoryMessage.new(releases: []))
    _model, command = @app.update(Tentacle::StreamConnectedMessage.new)

    assert_instance_of Proc, command
    assert_includes @app.view, "LIVE"
    refute_includes @app.view, "CONNECTING"
  end

end

class AppQuitBehaviorTest < Minitest::Test
  class FakeMuteStore
    def muted_groups = []
    def mute(_group); end
    def unmute(_group); end
  end

  def setup
    @app = Tentacle::App.new(app_name: "test-app", color: false, mute_store: FakeMuteStore.new)
    @app.update(Bubbletea::WindowSizeMessage.new(width: 120, height: 30))
  end

  def key(name)
    Bubbletea::KeyMessage.new(name)
  end

  def test_escape_quits_from_main_view
    _model, command = @app.update(key("esc"))
    assert_instance_of Bubbletea::QuitCommand, command
  end

  def test_escape_returns_from_detail_without_quitting
    @app.update(Tentacle::LogLineMessage.new('2026-08-11T18:35:03Z app[web.1]: selected event'))
    @app.update(key("enter"))

    _model, command = @app.update(key("esc"))

    assert_nil command
    refute @app.instance_variable_get(:@detail_mode)
  end

  def test_ctrl_c_quits_even_while_search_is_open
    @app.update(key("/"))
    _model, command = @app.update(key("ctrl+c"))

    assert_instance_of Bubbletea::QuitCommand, command
  end
end
