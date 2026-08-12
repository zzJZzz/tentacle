# frozen_string_literal: true

require "bubbletea"
require "lipgloss"
require "bubbles"
begin
  require "ntcharts"
rescue LoadError
  # NTCharts is optional at runtime. Some native builds may not load on every WSL setup.
end
require "time"
require_relative "parser"
require_relative "stream"
require_relative "mute_store"
require_relative "release_history"

module Tentacle
  class App
    include Bubbletea::Model

    TABS = [
      [:overview, "Overview"],
      [:all, "All"],
      [:web, "Web"],
      [:errors, "Errors"],
      [:groups, "Groups"],
      [:slow, "Slow"],
      [:worker, "Worker"],
      [:heroku, "Heroku"],
      [:database, "Database"]
    ].freeze

    DUAL_SCREEN_MIN_WIDTH = 120
    LLM_LOG_LIMIT = 80

    TAB_DESCRIPTIONS = {
      overview: "Live health snapshot: request volume, errors, slow requests, and recurring failures.",
      all: "Every buffered Heroku log line, regardless of source or process.",
      web: "Rails web dyno activity. Best first stop when reproducing a request-level bug.",
      errors: "Chronological failures: Rails exceptions, HTTP 5xxs, Heroku H-codes, and database errors.",
      groups: "Repeated failures grouped together so noisy or recurring problems stand out quickly.",
      slow: "Requests whose Heroku service time is at or above the configured slow threshold.",
      worker: "Background job and worker dyno activity, including Sidekiq-style failures.",
      heroku: "Heroku router and platform output: routing, H-codes, restarts, warnings, and platform events.",
      database: "Database-related output, including connection failures, query errors, and database-side diagnostics.",
      request: "All buffered lines correlated to the selected Heroku request ID."
    }.freeze

    RESET = "\e[0m"
    BOLD = "\e[1m"
    DIM = "\e[2m"
    REVERSE = "\e[7m"
    RED = "\e[31m"
    YELLOW = "\e[33m"
    CYAN = "\e[36m"
    GREEN = "\e[32m"

    def initialize(app_name:, max_lines: 5_000, color: true, slow_ms: 1_000, mute_store: nil, release_history: nil, clock: nil, clipboard_writer: nil)
      @app_name = app_name
      @max_lines = max_lines
      @slow_ms = slow_ms
      @color = color
      @parser = Parser.new
      @stream = LogStream.new(app_name)
      @mute_store = mute_store || MuteStore.new(app_name)
      @muted_groups = @mute_store.muted_groups
      @show_muted_groups = false
      @release_history = release_history || ReleaseHistory.new(app_name)
      @clock = clock || -> { Time.now.utc }
      @clipboard_writer = clipboard_writer
      @releases = []
      @release_error = nil
      @releases_loaded = false
      @stream_connected = false

      @incident_started_at = nil
      @incident_ended_at = nil
      @incident_start_marker = nil
      @incident_end_marker = nil
      @incident_only = false

      build_styles
      build_bubbles

      @events = []
      @tab = :overview
      @width = 100
      @height = 30
      @paused = false
      @stream_ended = nil
      @follow = true
      @scroll_from_bottom = 0
      @selected_event = nil
      @search_mode = false
      @search = String.new
      @search_draft = String.new
      @search_before_edit = String.new
      @detail_mode = false
      @help_mode = false
      @dual_screen = false
      @clipboard_notice = nil
      @request_id = nil
      @previous_tab = nil

      @group_occurrences_key = nil
      @selected_group_key = nil
      @group_scroll_from_top = 0

    end

    def init
      [self, Bubbletea.batch(next_release_command, next_log_command, @spinner.tick)]
    end

    def update(message)
      @spinner, spinner_command = @spinner.update(message)

      result = case message
      when ReleaseHistoryMessage
        @releases = message.releases
        @release_error = message.error
        @releases_loaded = true
        [self, nil]
      when StreamConnectedMessage
        @stream_connected = true
        command = @paused ? nil : next_log_command
        [self, command]
      when LogLineMessage
        @stream_connected = true
        append_event(@parser.parse(message.line))
        command = @paused ? nil : next_log_command
        [self, command]
      when StreamEndedMessage
        @stream_connected = true
        @stream_ended = message.reason || "stream ended"
        [self, nil]
      when Bubbletea::WindowSizeMessage
        @width = [message.width, 20].max
        @height = [message.height, 8].max
        resize_viewports
        [self, nil]
      when Bubbletea::KeyMessage
        handle_key(message)
      else
        [self, nil]
      end

      spinner_command = nil unless startup_loading?
      model, command = result
      [model, combine_commands(command, spinner_command)]
    end

    def view
      return help_view if @help_mode
      return dual_screen_view if @dual_screen && @width >= DUAL_SCREEN_MIN_WIDTH

      primary_view
    end

    def primary_view
      if @detail_mode
        detail_view
      elsif @tab == :overview
        overview_view
      elsif groups_index?
        groups_view
      else
        events_view
      end
    end

    private

    def next_release_command
      -> { @release_history.fetch_message }
    end

    def next_log_command
      -> { @stream.next_message }
    end

    def build_bubbles
      @spinner = Bubbles::Spinner.new
      @spinner.spinner = Bubbles::Spinners::DOT
      @help = Bubbles::Help.new
      @keys = {
        views: Bubbles::Key.binding(keys: %w[1 2 3 4 5 6 7 8 9], help: ["1–9", "views"]),
        tabs: Bubbles::Key.binding(keys: ["tab", "shift+tab"], help: ["tab", "next"]),
        move: Bubbles::Key.binding(keys: %w[up down j k], help: ["↑↓", "select"]),
        detail: Bubbles::Key.binding(keys: ["enter"], help: ["enter", "detail"]),
        errors: Bubbles::Key.binding(keys: %w[n N], help: ["n/N", "error"]),
        mute: Bubbles::Key.binding(keys: ["m"], help: ["m", "mute"]),
        incident: Bubbles::Key.binding(keys: ["s"], help: ["s", "incident"]),
        scope: Bubbles::Key.binding(keys: ["i"], help: ["i", "scope"]),
        llm: Bubbles::Key.binding(keys: ["L"], help: ["L", "LLM"]),
        split: Bubbles::Key.binding(keys: ["d"], help: ["d", "split"]),
        search: Bubbles::Key.binding(keys: ["/"], help: ["/", "search"]),
        back: Bubbles::Key.binding(keys: ["esc"], help: ["esc", "back"]),
        help: Bubbles::Key.binding(keys: ["?"], help: ["?", "help"]),
        quit: Bubbles::Key.binding(keys: ["q", "esc", "ctrl+c"], help: ["q/Esc", "quit"])
      }
      resize_viewports
    end

    def resize_viewports
      width = @width || 100
      height = @height || 30
      viewport_height = [height - 1, 1].max
      @detail_viewport = Bubbles::Viewport.new(width: [width, 20].max, height: viewport_height)
      @help_viewport = Bubbles::Viewport.new(width: [width, 20].max, height: viewport_height)
    end

    def startup_loading?
      !@releases_loaded || !@stream_connected
    end

    def combine_commands(*commands)
      active = commands.compact
      return nil if active.empty?
      return active.first if active.length == 1

      Bubbletea.batch(*active)
    end

    def append_event(event)
      @events << event
      overflow = @events.length - @max_lines
      @events.shift(overflow) if overflow.positive?

      if @follow && event_matches_current_view?(event)
        @scroll_from_bottom = 0
        @selected_event = event
      end

      normalize_group_selection! if groups_index?
    end

    def handle_key(message)
      key = message.to_s

      if @help_mode
        return quit if ["q", "ctrl+c"].include?(key)

        if ["?", "esc", "enter"].include?(key)
          @help_mode = false
          return [self, nil]
        end

        @help_viewport, command = @help_viewport.update(message)
        return [self, command]
      end

      if @detail_mode
        return quit if ["q", "ctrl+c"].include?(key)

        case key
        when "?"
          @help_mode = true
        when "esc", "enter"
          @detail_mode = false
        when "r"
          @detail_mode = false
          open_request_view
        when "m"
          toggle_mute_selected
        when "y"
          copy_selected(:smart)
        when "Y"
          copy_selected(:raw)
        when "L"
          copy_llm_context
        when "d"
          toggle_dual_screen
        else
          @detail_viewport, command = @detail_viewport.update(message)
          return [self, command]
        end
        return [self, nil]
      end

      return handle_search_key(message) if @search_mode

      case key
      when "q", "ctrl+c"
        quit
      when "?"
        @help_mode = true
        [self, nil]
      when "1", "2", "3", "4", "5", "6", "7", "8", "9"
        select_tab(TABS[key.to_i - 1][0])
        [self, nil]
      when "tab"
        cycle_tab(1)
        [self, nil]
      when "shift+tab"
        cycle_tab(-1)
        [self, nil]
      when "up", "k"
        groups_index? ? move_group_selection(-1) : move_selection(-1)
        [self, nil]
      when "down", "j"
        groups_index? ? move_group_selection(1) : move_selection(1)
        [self, nil]
      when "n"
        jump_to_error(1) unless groups_index? || @tab == :overview
        [self, nil]
      when "N"
        jump_to_error(-1) unless groups_index? || @tab == :overview
        [self, nil]
      when "pgup"
        groups_index? ? move_group_selection(-group_page_size) : scroll_page(1)
        [self, nil]
      when "pgdown"
        groups_index? ? move_group_selection(group_page_size) : scroll_page(-1)
        [self, nil]
      when "home", "g"
        groups_index? ? jump_to_first_group : jump_to_top
        [self, nil]
      when "end", "G", "f"
        groups_index? ? jump_to_last_group : follow_latest
        [self, nil]
      when "space"
        @paused = !@paused
        command = @paused ? nil : next_log_command
        [self, command]
      when "/"
        begin_search
        [self, nil]
      when "x"
        @search = String.new
        reset_after_filter_change
        [self, nil]
      when "m"
        toggle_mute_selected
        [self, nil]
      when "M"
        if @tab == :groups
          @show_muted_groups = !@show_muted_groups
          normalize_group_selection!
          @clipboard_notice = @show_muted_groups ? "showing muted groups" : "muted groups hidden"
        else
          @clipboard_notice = "M is available in Groups"
        end
        [self, nil]
      when "s"
        toggle_incident_session
        [self, nil]
      when "i"
        toggle_incident_scope
        [self, nil]
      when "c"
        @events.clear
        @selected_event = nil
        @selected_group_key = nil
        @group_occurrences_key = nil
        @scroll_from_bottom = 0
        @group_scroll_from_top = 0
        reset_incident_session
        @clipboard_notice = "buffer cleared · incident reset"
        [self, nil]
      when "enter"
        if groups_index?
          open_group_occurrences
        else
          @detail_mode = !@selected_event.nil?
        end
        [self, nil]
      when "r"
        open_request_view
        [self, nil]
      when "esc"
        if @group_occurrences_key
          close_group_occurrences
          [self, nil]
        elsif @tab == :request
          close_request_view
          [self, nil]
        else
          quit
        end
      when "R"
        @stream.restart
        @stream_ended = nil
        @releases_loaded = false
        @stream_connected = false
        @release_error = nil
        [self, Bubbletea.batch(next_release_command, next_log_command, @spinner.tick)]
      when "y"
        copy_selected(:smart)
        [self, nil]
      when "Y"
        copy_selected(:raw)
        [self, nil]
      when "L"
        copy_llm_context
        [self, nil]
      when "d"
        toggle_dual_screen
        [self, nil]
      else
        [self, nil]
      end
    end

    def quit
      @stream.close
      [self, Bubbletea.quit]
    end

    def begin_search
      @search_mode = true
      @search_before_edit = @search.dup
      @search_draft = @search.dup
    end

    def handle_search_key(message)
      key = message.to_s
      return quit if key == "ctrl+c"

      case key
      when "enter"
        @search = @search_draft.dup
        @search_mode = false
        reset_after_filter_change
      when "esc"
        @search = @search_before_edit.dup
        @search_mode = false
        reset_after_filter_change
      when "backspace"
        @search_draft = @search_draft[0...-1].to_s.dup
      when "ctrl+u"
        @search_draft = String.new
      else
        text = if message.respond_to?(:runes?) && message.runes?
          message.char.to_s
        elsif message.respond_to?(:space?) && message.space?
          " "
        else
          String.new
        end
        @search_draft << text unless text.empty?
      end

      # Search previews live while typing, but Esc can still restore the old filter.
      @search = @search_draft.dup if @search_mode
      reset_after_filter_change if @search_mode
      [self, nil]
    end

    def reset_after_filter_change
      if groups_index?
        @group_scroll_from_top = 0
        @selected_group_key = nil unless filtered_error_groups.any? { |group| group[:key] == @selected_group_key }
        normalize_group_selection!
      else
        @follow = true
        @scroll_from_bottom = 0
        @selected_event = filtered_events.last
      end
    end

    def select_tab(tab)
      @request_id = nil
      @previous_tab = nil
      @group_occurrences_key = nil
      @detail_mode = false
      @tab = tab

      if tab == :groups
        @follow = false
        @group_scroll_from_top = 0
        normalize_group_selection!
      else
        follow_latest
      end
    end

    def cycle_tab(direction)
      index = TABS.index { |tab, _| tab == @tab } || 0
      select_tab(TABS[(index + direction) % TABS.length][0])
    end

    def move_selection(direction)
      visible = filtered_events
      return if visible.empty?

      @follow = false
      index = @selected_event ? visible.index(@selected_event) : nil
      index ||= visible.length - 1
      next_index = [[index + direction, 0].max, visible.length - 1].min
      @selected_event = visible[next_index]
      keep_selection_visible(visible, next_index)
    end

    def jump_to_error(direction)
      visible = filtered_events
      return if visible.empty?

      error_indexes = visible.each_index.select { |index| active_error?(visible[index]) }
      if error_indexes.empty?
        @clipboard_notice = "no errors in this view"
        return
      end

      @follow = false
      current_index = @selected_event ? visible.index(@selected_event) : nil
      current_index ||= direction.positive? ? -1 : visible.length

      target_index = if direction.positive?
        error_indexes.find { |index| index > current_index } || error_indexes.first
      else
        error_indexes.reverse.find { |index| index < current_index } || error_indexes.last
      end

      @selected_event = visible[target_index]
      keep_selection_visible(visible, target_index)
    end

    def scroll_page(direction, amount: nil)
      @follow = false
      step = amount || [@height - 8, 5].max
      max_scroll = [filtered_events.length - 1, 0].max
      @scroll_from_bottom = [[@scroll_from_bottom + (direction * step), 0].max, max_scroll].min
    end

    def jump_to_top
      visible = filtered_events
      return if visible.empty?

      @follow = false
      @selected_event = visible.first
      @scroll_from_bottom = [visible.length - 1, 0].max
    end

    def follow_latest
      @follow = true
      @scroll_from_bottom = 0
      @selected_event = filtered_events.last
    end

    def keep_selection_visible(visible, selected_index)
      body_height = event_body_height
      start_index = [visible.length - body_height - @scroll_from_bottom, 0].max
      end_index = start_index + body_height - 1

      if selected_index < start_index
        @scroll_from_bottom = visible.length - body_height - selected_index
      elsif selected_index > end_index
        @scroll_from_bottom = [visible.length - body_height - (selected_index - body_height + 1), 0].max
      end
    end

    def open_request_view
      return unless @selected_event&.request_id

      @previous_tab = @tab
      @request_id = @selected_event.request_id
      @group_occurrences_key = nil
      @tab = :request
      follow_latest
    end

    def close_request_view
      return unless @tab == :request

      @tab = @previous_tab || :web
      @request_id = nil
      @previous_tab = nil
      follow_latest
    end

    def groups_index?
      @tab == :groups && @group_occurrences_key.nil?
    end

    def open_group_occurrences
      return unless @selected_group_key

      @group_occurrences_key = @selected_group_key
      @follow = true
      @scroll_from_bottom = 0
      @selected_event = filtered_events.last
    end

    def close_group_occurrences
      return unless @tab == :groups && @group_occurrences_key

      @group_occurrences_key = nil
      @selected_event = nil
      @follow = false
      normalize_group_selection!
    end

    def error_groups
      groups = {}

      error_group_source_events.each_with_index do |event, index|
        next unless event.error?

        key = event.error_group || "Other error"
        group = (groups[key] ||= {
          key: key,
          label: key,
          count: 0,
          latest_index: index,
          latest_event: event,
          categories: Hash.new(0),
          muted: muted_group?(key)
        })

        group[:count] += 1
        group[:latest_index] = index
        group[:latest_event] = event
        group[:categories][event.source_label] += 1
      end

      groups.values.sort_by { |group| [-group[:count], -group[:latest_index]] }
    end

    def filtered_error_groups
      groups = error_groups
      groups = groups.reject { |group| group[:muted] } unless @show_muted_groups
      return groups if @search.empty?

      needle = @search.downcase
      groups.select do |group|
        group[:label].downcase.include?(needle) ||
          error_group_source_events.any? { |event| event.error? && event.error_group == group[:key] && event.raw.downcase.include?(needle) }
      end
    end

    def normalize_group_selection!
      groups = filtered_error_groups
      if groups.empty?
        @selected_group_key = nil
        @group_scroll_from_top = 0
        return
      end

      unless groups.any? { |group| group[:key] == @selected_group_key }
        @selected_group_key = groups.first[:key]
      end
      keep_group_selection_visible(groups)
    end

    def move_group_selection(direction)
      groups = filtered_error_groups
      return if groups.empty?

      index = groups.index { |group| group[:key] == @selected_group_key } || 0
      next_index = [[index + direction, 0].max, groups.length - 1].min
      @selected_group_key = groups[next_index][:key]
      keep_group_selection_visible(groups)
    end

    def jump_to_first_group
      groups = filtered_error_groups
      return if groups.empty?

      @selected_group_key = groups.first[:key]
      @group_scroll_from_top = 0
    end

    def jump_to_last_group
      groups = filtered_error_groups
      return if groups.empty?

      @selected_group_key = groups.last[:key]
      keep_group_selection_visible(groups)
    end

    def keep_group_selection_visible(groups)
      index = groups.index { |group| group[:key] == @selected_group_key } || 0
      height = group_body_height
      max_start = [groups.length - height, 0].max

      if index < @group_scroll_from_top
        @group_scroll_from_top = index
      elsif index >= @group_scroll_from_top + height
        @group_scroll_from_top = index - height + 1
      end

      @group_scroll_from_top = [[@group_scroll_from_top, 0].max, max_start].min
    end

    def group_page_size
      [group_body_height - 1, 1].max
    end

    def filtered_events
      source_events = incident_source_events
      events = case @tab
      when :overview
        source_events
      when :all
        source_events
      when :web
        source_events.select { |event| event.web? || event.incident? }
      when :errors
        source_events.select { |event| active_error?(event) || event.incident? }
      when :groups
        source_events.select { |event| (event.error? && event.error_group == @group_occurrences_key) || event.incident? }
      when :slow
        source_events.select { |event| (event.service_ms && event.service_ms >= @slow_ms) || event.incident? }
      when :worker
        source_events.select { |event| event.worker? || event.incident? }
      when :heroku
        source_events.select { |event| event.heroku? || event.incident? }
      when :database
        source_events.select { |event| event.database? || event.incident? }
      when :request
        source_events.select { |event| event.request_id == @request_id || event.raw.include?(@request_id.to_s) }
      else
        source_events
      end

      return events if @search.empty?

      needle = @search.downcase
      events.select { |event| event.incident? || event.raw.downcase.include?(needle) }
    end

    def event_matches_current_view?(event)
      return false if @incident_only && !event_in_incident?(event)

      matches = case @tab
      when :overview then true
      when :all then true
      when :web then event.web? || event.incident?
      when :errors then active_error?(event) || event.incident?
      when :groups then event.incident? || (@group_occurrences_key && event.error? && event.error_group == @group_occurrences_key)
      when :slow then event.incident? || (event.service_ms && event.service_ms >= @slow_ms)
      when :worker then event.worker? || event.incident?
      when :heroku then event.heroku? || event.incident?
      when :database then event.database? || event.incident?
      when :request then event.request_id == @request_id || event.raw.include?(@request_id.to_s)
      else true
      end

      matches && (@search.empty? || event.raw.downcase.include?(@search.downcase) || event.incident?)
    end

    def normalize_selection!(visible)
      @selected_event = visible.last if @follow && visible.any?
      @selected_event = nil if @selected_event && !visible.include?(@selected_event)
    end

    def visible_window(visible, body_height)
      return [] if visible.empty?

      max_scroll = [visible.length - body_height, 0].max
      @scroll_from_bottom = [@scroll_from_bottom, max_scroll].min
      start_index = [visible.length - body_height - @scroll_from_bottom, 0].max
      visible.slice(start_index, body_height) || []
    end

    def overview_view

      lines = []
      lines << header_line
      lines << tabs_line
      lines << description_line
      lines << search_line
      lines << incident_context_line
      lines << release_context_line
      lines << separator

      body_height = [@height - 9, 1].max
      overview_lines = overview_body(body_height)
      lines.concat(overview_lines.first(body_height))

      while lines.length < @height - 2
        lines << ""
      end

      lines << separator
      lines << footer_line
      lines.first(@height).join("\n")
    end

    def overview_body(body_height)
      metrics = minute_metrics(24)
      latest = metrics.last || { requests: 0, errors: 0, slow: 0 }
      metric_events = incident_source_events
      total_requests = metric_events.count { |event| event.category == :router }
      total_errors = metric_events.count { |event| active_error?(event) }
      muted_errors = metric_events.count { |event| event.error? && muted_group?(event.error_group) }
      total_slow = metric_events.count { |event| event.service_ms && event.service_ms >= @slow_ms }

      summary = [
        metric_badge(@incident_only ? "Incident" : "Buffered", metric_events.length, @styles[:metric_neutral]),
        metric_badge("Requests", total_requests, @styles[:metric_info]),
        metric_badge("Errors", total_errors, total_errors.positive? ? @styles[:metric_danger] : @styles[:metric_neutral]),
        metric_badge("Muted", muted_errors, muted_errors.positive? ? @styles[:metric_muted] : @styles[:metric_neutral]),
        metric_badge("Slow", total_slow, total_slow.positive? ? @styles[:metric_warning] : @styles[:metric_neutral]),
        metric_badge("Last min", "#{latest[:requests]} req", @styles[:metric_info])
      ].join("  ")

      lines = [truncate_ansi(summary, @width), ""]

      if body_height >= 12 && @width >= 72
        chart_width = [[((@width - 2) / 3) - 4, 12].max, 42].min
        chart_height = [[body_height / 3, 5].max, 8].min
        request_panel = chart_panel("Requests / min", metrics.map { |m| m[:requests] }, chart_width, chart_height, @chart_colors[:requests])
        error_panel = chart_panel("Errors / min", metrics.map { |m| m[:errors] }, chart_width, chart_height, @chart_colors[:errors])
        slow_panel = chart_panel("Slow / min", metrics.map { |m| m[:slow] }, chart_width, chart_height, @chart_colors[:slow])
        lines.concat(Lipgloss.join_horizontal(:top, request_panel, " ", error_panel, " ", slow_panel).split("\n"))
        lines << ""
      else
        lines << styled("Charts appear when the terminal is at least 72 columns wide and 12 body rows tall.", @styles[:muted])
        lines << ""
      end

      groups = error_groups.reject { |group| group[:muted] }.first([body_height - lines.length - 2, 5].max)
      lines << styled("Recurring errors", @styles[:section])
      if groups.empty?
        lines << styled("  No errors in the current buffer.", @styles[:muted])
      else
        groups.first(5).each do |group|
          count = styled(group[:count].to_s.rjust(4), @styles[:danger_badge])
          lines << truncate_ansi("  #{count}  #{group[:label]}", @width)
        end
      end

      if @releases.any? && lines.length < body_height - 2
        lines << ""
        lines << styled("Recent releases", @styles[:section])
        @releases.last(3).reverse_each do |release|
          icon = release.deploy? ? "🚀" : "◆"
          status = release.status.to_s.empty? ? "" : " · #{release.status}"
          lines << truncate_ansi("  #{icon} #{release.version_label}  #{release.description}#{status}", @width)
        end
      end

      lines
    end

    def chart_panel(title, values, width, height, color)
      body = if defined?(Ntcharts::Sparkline)
        chart = Ntcharts::Sparkline.new(width, height)
        chart.style = Lipgloss::Style.new.foreground(color) if @color
        values.each { |value| chart.push(value) }
        chart.draw_braille
        styled(title, @styles[:chart_title]) + "\n" + chart.view
      else
        styled(title, @styles[:chart_title]) + "\n" + fallback_sparkline(values, width)
      end
      @styles[:chart_panel].render(body)
    rescue StandardError => error
      @styles[:chart_panel].render("#{title}\nchart unavailable: #{error.class}")
    end

    def fallback_sparkline(values, width)
      ticks = %w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █]
      sample = values.last([width, 1].max)
      return "" if sample.empty?
      max = sample.max.to_f
      return ticks.first * sample.length if max <= 0

      sample.map do |value|
        index = ((value.to_f / max) * (ticks.length - 1)).round
        ticks[[[index, 0].max, ticks.length - 1].min]
      end.join
    end

    def minute_metrics(bucket_count)
      parsed = incident_source_events.filter_map do |event|
        next unless event.timestamp
        begin
          [Time.iso8601(event.timestamp), event]
        rescue ArgumentError
          nil
        end
      end
      return Array.new(bucket_count) { { requests: 0, errors: 0, slow: 0 } } if parsed.empty?

      latest_minute = Time.at((parsed.map(&:first).max.to_i / 60) * 60).utc
      first_minute = latest_minute - ((bucket_count - 1) * 60)
      buckets = Array.new(bucket_count) { { requests: 0, errors: 0, slow: 0 } }

      parsed.each do |time, event|
        index = ((time - first_minute) / 60).floor
        next if index.negative? || index >= bucket_count

        buckets[index][:requests] += 1 if event.category == :router
        buckets[index][:errors] += 1 if active_error?(event)
        buckets[index][:slow] += 1 if event.service_ms && event.service_ms >= @slow_ms
      end

      buckets
    end

    def metric_badge(label, value, style)
      styled(" #{label} #{value} ", style)
    end

    def events_view
      lines = []
      lines << header_line
      lines << tabs_line
      lines << description_line
      lines << search_line
      lines << incident_context_line
      lines << release_context_line
      lines << separator

      visible = filtered_events
      normalize_selection!(visible)
      window = visible_window(visible, event_body_height)
      if visible.empty? && @tab == :database
        lines << styled("No database-related log lines detected.", @styles[:muted])
      else
        window.each do |event|
          lines << render_event(event, selected: event.equal?(@selected_event))
        end
      end

      while lines.length < @height - 2
        lines << ""
      end

      lines << separator
      lines << footer_line
      lines.first(@height).join("\n")
    end

    def groups_view
      normalize_group_selection!

      lines = []
      lines << header_line
      lines << tabs_line
      lines << description_line
      lines << search_line
      lines << incident_context_line
      lines << release_context_line
      lines << separator

      groups = filtered_error_groups
      window = groups.slice(@group_scroll_from_top, group_body_height) || []
      if groups.empty?
        lines << paint("No matching error groups yet.", DIM)
      else
        window.each do |group|
          lines << render_group(group, selected: group[:key] == @selected_group_key)
        end
      end

      while lines.length < @height - 2
        lines << ""
      end

      lines << separator
      lines << footer_line
      lines.first(@height).join("\n")
    end

    def event_body_height
      [@height - 9, 1].max
    end

    def group_body_height
      [@height - 9, 1].max
    end

    def dual_screen_view
      total_width = @width
      divider_width = 3
      right_width = [(total_width * 0.40).floor, 38].max
      left_width = total_width - right_width - divider_width

      left = with_width(left_width) { primary_view }
      right = with_width(right_width) { llm_preview_view }
      divider = Array.new(@height, " │ ").join("\n")

      Lipgloss.join_horizontal(:top, left, divider, right)
    end

    def with_width(width)
      previous_width = @width
      @width = [width, 20].max
      yield
    ensure
      @width = previous_width
    end

    def llm_preview_view
      content_width = [@width - 2, 1].max
      wrapped = llm_context_payload.lines.flat_map do |line|
        text = line.chomp
        text.empty? ? [""] : wrap_text(text, content_width)
      end

      lines = []
      lines << styled(" LLM COPY PREVIEW ", @styles[:title])
      lines << styled(" L copies this redacted context · d closes split", @styles[:description])
      lines << styled("─" * [@width, 1].max, @styles[:muted])

      viewport = Bubbles::Viewport.new(width: [@width, 20].max, height: [@height - 4, 1].max)
      viewport.content = wrapped.join("\n")
      body = viewport.view.split("\n", -1)
      lines.concat(body)
      while lines.length < @height - 1
        lines << ""
      end
      lines << styled(" Preview only · clipboard includes the full context ", @styles[:footer])
      lines.first(@height).join("\n")
    end

    def header_line
      state_label, state_style = if @stream_ended
        ["DISCONNECTED", @styles[:danger_badge]]
      elsif @paused
        ["PAUSED", @styles[:warning_badge]]
      elsif startup_loading?
        ["#{@spinner.view} CONNECTING", @styles[:info_badge]]
      else
        ["LIVE", @styles[:success_badge]]
      end

      error_count = @events.count { |event| active_error?(event) }
      muted_error_count = @events.count { |event| event.error? && muted_group?(event.error_group) }
      group_count = error_groups.count { |group| !group[:muted] }
      title = styled(" TENTACLE ", @styles[:title]) + " " + styled(@app_name, @styles[:app])
      state = styled(state_label, state_style)
      muted_text = muted_error_count.positive? ? "  #{muted_error_count} muted" : ""
      stats = "#{state}  #{@events.length} lines  #{error_count} errors  #{group_count} groups#{muted_text}"
      truncate_ansi(pad_between_ansi(title, stats), @width)
    end

    def tabs_line
      rendered = TABS.map.with_index do |(tab, label), index|
        count = tab_count(tab)
        show_count = @width >= 110 && count.positive? && [:errors, :groups, :slow].include?(tab)
        count_text = show_count ? " #{compact_count(count)}" : ""
        text = "#{index + 1}:#{label}#{count_text}"
        style = tab == @tab ? @styles[:tab_active] : @styles[:tab_inactive]
        styled(text, style)
      end

      if @tab == :request
        rendered << styled(" Request #{@request_id.to_s[0, 12]} ", @styles[:tab_context])
      elsif @tab == :groups && @group_occurrences_key
        rendered << styled(" Group: #{truncate(@group_occurrences_key, 28)} ", @styles[:tab_context])
      end

      truncate_ansi(rendered.join(" "), @width)
    end

    def description_line
      description = if @tab == :groups && @group_occurrences_key
        "Occurrences of #{@group_occurrences_key}. Enter inspects a line; Esc returns to grouped errors."
      else
        TAB_DESCRIPTIONS.fetch(@tab, "")
      end

      threshold = @tab == :slow ? " Current threshold: #{@slow_ms}ms." : ""
      truncate_ansi(styled("  #{description}#{threshold}", @styles[:description]), @width)
    end

    def compact_count(count)
      return count.to_s if count < 1_000
      return format("%.1fk", count / 1_000.0) if count < 100_000

      "99k+"
    end

    def tab_count(tab)
      scope = incident_source_events
      case tab
      when :overview then scope.length
      when :all then scope.length
      when :web then scope.count(&:web?)
      when :errors then scope.count { |event| active_error?(event) }
      when :groups then error_groups.count { |group| !group[:muted] }
      when :slow then scope.count { |event| event.service_ms && event.service_ms >= @slow_ms }
      when :worker then scope.count(&:worker?)
      when :heroku then scope.count(&:heroku?)
      when :database then scope.count(&:database?)
      else 0
      end
    end

    def search_line
      stream_notice = @stream_ended ? "  stream: #{@stream_ended} (R reconnect)" : ""

      content = if @search_mode
        "🔎 #{@search_draft}▌  Enter apply · Esc cancel · Ctrl-U clear"
      elsif !@search.empty?
        "🔎 #{@search}  ·  x clears"
      elsif @tab == :request
        "🔎 Filter this request view with /  ·  request_id=#{@request_id}"
      elsif @tab == :overview
        "Use 2–9 or Tab to investigate · ↑↓ selects · Enter opens details · ? shows all controls"
      else
        "🔎 / search current view"
      end

      notices = "#{stream_notice}#{@clipboard_notice ? "  ·  #{@clipboard_notice}" : ""}"
      truncate_ansi(styled(" #{content}#{notices}", @search_mode ? @styles[:search_active] : @styles[:search]), @width)
    end

    def render_event(event, selected: false)
      marker = selected ? "▶ " : "  "
      database_badge = @tab == :database && event.database? ? "[#{event.database_label}] " : ""
      prefix = "#{marker}#{event.time_label} #{event.source_label.ljust(6)} #{database_badge}"
      text = truncate(prefix + event.message.to_s, @width)
      if selected
        styled(text, @styles[:selected])
      elsif event.incident?
        styled(text, @styles[:incident_marker])
      elsif event.release?
        styled(text, @styles[:release])
      elsif event.error? && muted_group?(event.error_group)
        styled(text, @styles[:muted_error])
      elsif event.error?
        styled(text, @styles[:error])
      else
        styled(text, @styles.fetch("source_#{event.category}".to_sym, @styles[:muted]))
      end
    end

    def render_group(group, selected: false)
      category_summary = group[:categories]
        .sort_by { |_label, count| -count }
        .first(3)
        .map { |label, count| "#{label} #{count}" }
        .join(" · ")

      count = group[:count].to_s.rjust(5)
      latest = group[:latest_event]&.time_label || "--:--:--"
      label_width = [@width - 34 - category_summary.length, 18].max
      label = truncate(group[:label], label_width)
      marker = selected ? "▶" : " "
      muted = group[:muted] ? " [MUTED]" : ""
      text = "#{marker} #{count}  #{label.ljust(label_width)}#{muted}  #{category_summary}  #{latest}"
      text = truncate(text, @width)
      if selected
        styled(text, @styles[:selected])
      elsif group[:muted]
        styled(text, @styles[:muted_error])
      else
        styled(text, @styles[:error])
      end
    end

    def footer_line
      status, bindings = if @tab == :overview
        [nil, %i[views incident scope llm split tabs help quit]]
      elsif groups_index?
        [group_selection_status, %i[move detail mute incident scope llm split search help quit]]
      elsif @tab == :groups && @group_occurrences_key
        [event_selection_status, %i[move detail mute incident scope llm split back help quit]]
      elsif @tab == :request
        [event_selection_status, %i[move detail errors incident llm split back search help quit]]
      else
        [event_selection_status, %i[move detail errors mute incident scope llm split search help quit]]
      end

      hints = @help.short_help_view(bindings.map { |name| @keys.fetch(name) })
      text = [status, hints].compact.reject(&:empty?).join(" · ")
      truncate_ansi(styled(" #{text}", @styles[:footer]), @width)
    end

    def event_selection_status
      visible = filtered_events
      return "no matching lines" if visible.empty?

      index = @selected_event ? visible.index(@selected_event) : nil
      index ||= visible.length - 1
      follow = @follow ? " · FOLLOW" : ""
      "selected #{index + 1}/#{visible.length}#{follow}"
    end

    def group_selection_status
      groups = filtered_error_groups
      return "no matching groups" if groups.empty?

      index = groups.index { |group| group[:key] == @selected_group_key } || 0
      "selected #{index + 1}/#{groups.length}"
    end

    def detail_view
      event = @selected_event
      return "No event selected\n\nEsc to return" unless event

      lines = []
      lines << paint(" Event detail ", REVERSE, BOLD)
      lines << ""
      lines << field("Time", event.timestamp)
      lines << field("Source", event.source)
      lines << field("Process", event.process)
      lines << field("Category", event.category)
      lines << field("Database", event.database_label)
      lines << field("Status", event.status)
      lines << field("Method", event.method)
      lines << field("Path", event.path)
      lines << field("Service", event.service_ms && "#{event.service_ms}ms")
      lines << field("Request ID", event.request_id)
      lines << field("Error", event.error? ? "yes" : "no")
      lines << field("Error group", event.error_group)
      lines << field("Muted", event.error_group && muted_group?(event.error_group) ? "yes" : "no")
      lines << field("Incident", incident_membership_label(event)) if @incident_started_at
      if (release = release_before_event(event))
        lines << field("Prior release", "#{release.version_label} · #{release.description}")
        lines << field("After release", duration_after_release(event, release))
      end
      lines << ""
      lines << paint("Raw log", BOLD)
      lines.concat(wrap_text(event.raw, [@width, 20].max))

      context = buffered_context(event, 3)
      if context.length > 1
        lines << ""
        lines << paint("Buffered context (±3 lines)", BOLD, CYAN)
        context.each do |candidate|
          marker = candidate.equal?(event) ? "▶" : " "
          summary = "#{marker} #{candidate.time_label} #{candidate.source_label.ljust(6)} #{candidate.message}"
          lines << truncate(summary, @width)
        end
      end

      if event.request_id
        related = @events.select { |candidate| candidate.raw.include?(event.request_id) }
        lines << ""
        lines << paint("Related buffered lines (#{related.length})", BOLD, CYAN)
        related.last([@height / 3, 6].max).each do |candidate|
          lines.concat(wrap_text(candidate.raw, [@width, 20].max))
        end
      end

      footer = paint("↑↓ scroll   Enter/Esc back   r request   m mute   y ID/raw   Y raw   L LLM   d split   ? help   q quit", DIM)
      viewport_with_footer(@detail_viewport, lines.join("\n"), footer)
    end

    def buffered_context(event, radius)
      index = @events.index(event)
      return [event] unless index

      first = [index - radius, 0].max
      last = [index + radius, @events.length - 1].min
      @events[first..last] || [event]
    end

    def help_view
      lines = []
      lines << paint(" Tentacle — controls ", REVERSE, BOLD)
      lines << ""
      lines << paint("Views", BOLD, CYAN)
      lines << "  1 Overview   2 All   3 Web   4 Errors   5 Groups   6 Slow   7 Worker   8 Heroku   9 Database"
      lines << "  Tab / Shift-Tab       next / previous view"
      lines << ""
      lines << paint("Navigate", BOLD, CYAN)
      lines << "  ↑ / ↓   or j / k      move selection"
      lines << "  PgUp / PgDn           page"
      lines << "  n / N                 next / previous error in the current view"
      lines << "  g / Home              oldest / first"
      lines << "  G / End / f           newest and follow live logs"
      lines << ""
      lines << paint("Investigate", BOLD, CYAN)
      lines << "  Enter                 event detail; in Groups, open occurrences"
      lines << "                        detail includes nearby buffered context"
      lines << "  r                     all buffered lines for selected request_id"
      lines << "  /                     search/filter current view (Enter applies, Esc cancels)"
      lines << "  x                     clear search"
      lines << "  y                     copy request ID, or raw line if none"
      lines << "  Y                     copy full raw log line"
      lines << "  L                     copy a redacted, LLM-ready diagnostic context"
      lines << "  d                     toggle dual-screen: normal UI left, LLM copy preview right"
      lines << "                        dual-screen requires a terminal at least #{DUAL_SCREEN_MIN_WIDTH} columns wide"
      lines << "  Esc                   back from nested views; from the main view, quit"
      lines << "  m                     mute/unmute selected error group"
      lines << "  M                     in Groups, show/hide muted groups"
      lines << ""
      lines << paint("Incident / reproduction session", BOLD, CYAN)
      lines << "  s                     start incident; press s again to stop it"
      lines << "  i                     toggle incident-only scope across Overview/Errors/Groups/raw views"
      lines << "                        markers remain visible so the reproduction boundary is obvious"
      lines << ""
      lines << paint("Stream", BOLD, CYAN)
      lines << "  Space                 pause/resume consuming new lines"
      lines << "  R                     reconnect Heroku stream"
      lines << "  c                     clear in-memory buffer"
      lines << "  q                     quit when not typing in search"
      lines << "  Ctrl-C                quit immediately"
      lines << ""
      lines << paint("Mute / ignore noise", BOLD, CYAN)
      lines << "  Muted groups disappear from Errors, Groups, Overview counts/charts, and n/N jumps."
      lines << "  They remain visible (dimmed) in raw All/Web/Worker/Database views. Mutes persist per app."
      lines << ""
      lines << paint("Release context", BOLD, CYAN)
      lines << "  Release history is loaded from `heroku releases --json`. The context line and event detail"
      lines << "  show the latest release before the selected event; live app[api] deploy lines are highlighted."
      lines << ""
      lines << paint("Slow requests", BOLD, CYAN)
      lines << "  Slow shows requests with service time >= #{@slow_ms}ms (change with --slow-ms)."
      lines << ""
      lines << paint("Error Groups", BOLD, CYAN)
      lines << "  Groups combine repeated exceptions, Heroku H-codes, HTTP 5xxs,"
      lines << "  and database-native failures such as PostgreSQL FATAL and MySQL/MariaDB errors. Select a group and press Enter to"
      lines << "  see the individual occurrences, then Enter again for full detail."

      footer = paint("↑↓ / PgUp/PgDn scroll   ? / Esc / Enter closes help   q quits", DIM)
      viewport_with_footer(@help_viewport, lines.join("\n"), footer)
    end

    def viewport_with_footer(viewport, content, footer)
      viewport.content = content
      visible = viewport.view.split("\n", -1)
      available = [@height - 1, 1].max
      visible = visible.first(available)
      while visible.length < available
        visible << ""
      end

      scroll = if viewport.at_bottom?
        ""
      else
        " · #{(viewport.scroll_percent * 100).round}%"
      end
      visible << truncate_ansi("#{footer}#{scroll}", @width)
      visible.first(@height).join("\n")
    end

    def toggle_incident_session
      if incident_active?
        finish_incident_session
      else
        start_incident_session
      end
      reset_after_incident_change
    end

    def start_incident_session
      now = @clock.call.utc
      @incident_started_at = now
      @incident_ended_at = nil
      @incident_end_marker = nil
      @incident_start_marker = build_incident_marker("STARTED", now)
      append_event(@incident_start_marker)
      @clipboard_notice = "incident started · reproduce the problem now"
    end

    def finish_incident_session
      now = @clock.call.utc
      @incident_ended_at = now
      @incident_end_marker = build_incident_marker("ENDED", now)
      append_event(@incident_end_marker)
      @clipboard_notice = "incident stopped · i toggles incident-only scope"
    end

    def reset_incident_session
      @incident_started_at = nil
      @incident_ended_at = nil
      @incident_start_marker = nil
      @incident_end_marker = nil
      @incident_only = false
    end

    def toggle_incident_scope
      unless @incident_started_at
        @clipboard_notice = "no incident yet · press s when you begin reproducing"
        return
      end

      @incident_only = !@incident_only
      @clipboard_notice = @incident_only ? "incident-only scope ON" : "incident-only scope OFF"
      reset_after_incident_change
    end

    def reset_after_incident_change
      if groups_index?
        @group_scroll_from_top = 0
        @selected_group_key = nil
        normalize_group_selection!
      elsif @tab != :overview
        @follow = true
        @scroll_from_bottom = 0
        @selected_event = filtered_events.last
      end
    end

    def incident_active?
      !@incident_started_at.nil? && @incident_ended_at.nil?
    end

    def build_incident_marker(action, time)
      Event.new(
        raw: "TENTACLE INCIDENT #{action} #{time.iso8601}",
        timestamp: time.iso8601,
        source: "tentacle",
        process: "incident",
        message: "──────── INCIDENT #{action} · #{time.getlocal.strftime('%H:%M:%S')} ────────",
        category: :incident,
        error: false
      )
    end

    def incident_source_events
      return @events unless @incident_only && @incident_started_at

      start_index = @events.index(@incident_start_marker)
      end_index = @incident_end_marker ? @events.index(@incident_end_marker) : nil

      if start_index
        last_index = end_index || (@events.length - 1)
        @events[start_index..last_index] || []
      else
        @events.select { |event| event_in_incident_by_time?(event) }
      end
    end

    def error_group_source_events
      incident_source_events
    end

    def event_in_incident?(event)
      return true unless @incident_started_at
      return true if event.equal?(@incident_start_marker) || event.equal?(@incident_end_marker)

      if (start_index = @events.index(@incident_start_marker)) && (event_index = @events.index(event))
        end_index = @incident_end_marker ? @events.index(@incident_end_marker) : nil
        return event_index >= start_index && (!end_index || event_index <= end_index)
      end

      event_in_incident_by_time?(event)
    end

    def event_in_incident_by_time?(event)
      time = event_time(event)
      return false unless time
      return false if time < @incident_started_at
      return false if @incident_ended_at && time > @incident_ended_at

      true
    end

    def incident_context_line
      text, style = if !@incident_started_at
        ["● Incident: none · s starts a reproduction session", @styles[:incident_context]]
      elsif incident_active?
        scope = @incident_only ? "INCIDENT-ONLY ON" : "all logs"
        elapsed = human_duration((@clock.call.utc - @incident_started_at).to_i)
        ["● INCIDENT ACTIVE · started #{@incident_started_at.getlocal.strftime('%H:%M:%S')} · #{elapsed} · #{scope} · s stops · i toggles scope", @styles[:incident_context_active]]
      else
        scope = @incident_only ? "INCIDENT-ONLY ON" : "all logs"
        duration = human_duration((@incident_ended_at - @incident_started_at).to_i)
        ["● Incident #{@incident_started_at.getlocal.strftime('%H:%M:%S')}–#{@incident_ended_at.getlocal.strftime('%H:%M:%S')} · #{duration} · #{scope} · s starts new · i toggles scope", @styles[:incident_context]]
      end

      truncate_ansi(styled(" #{text}", style), @width)
    end

    def human_duration(seconds)
      seconds = [seconds.to_i, 0].max
      return "#{seconds}s" if seconds < 60
      return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600

      "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
    end

    def incident_membership_label(event)
      event_in_incident?(event) ? "inside current session" : "outside current session"
    end

    def muted_group?(group_key)
      group_key && @muted_groups.include?(group_key.to_s)
    end

    def active_error?(event)
      event.error? && !muted_group?(event.error_group)
    end

    def toggle_mute_selected
      group_key = if groups_index?
        @selected_group_key
      else
        @selected_event&.error_group
      end
      unless group_key
        @clipboard_notice = "selected item has no error group"
        return
      end

      if muted_group?(group_key)
        @mute_store.unmute(group_key)
        @muted_groups.delete(group_key)
        @clipboard_notice = "unmuted: #{truncate(group_key, 34)}"
      else
        @mute_store.mute(group_key)
        @muted_groups << group_key unless @muted_groups.include?(group_key)
        @clipboard_notice = "muted: #{truncate(group_key, 34)} · M shows muted"
      end

      if groups_index?
        @selected_group_key = nil unless @show_muted_groups || !muted_group?(group_key)
        normalize_group_selection!
      else
        reset_after_filter_change if @tab == :errors
      end
    end

    def release_context_line
      text = if !@releases_loaded
        "◆ Release context: loading recent Heroku releases…"
      elsif @release_error
        "◆ Release context unavailable: #{@release_error}"
      elsif @releases.empty?
        "◆ Release context: no releases returned"
      else
        event = @selected_event
        release = event ? release_before_event(event) : @releases.last
        if release
          relation = event ? " · selected +#{duration_after_release(event, release)}" : " · latest"
          icon = release.deploy? ? "🚀" : "◆"
          "#{icon} #{release.version_label} #{release.description}#{relation} · #{release.status}"
        else
          "◆ No release predates the selected event in the fetched history"
        end
      end

      truncate_ansi(styled(" #{text}", @styles[:release_context]), @width)
    end

    def release_before_event(event)
      event_time = event_time(event)
      return @releases.last unless event_time

      @releases.reverse.find do |release|
        release_time = release.time
        release_time && release_time <= event_time
      end
    end

    def event_time(event)
      return nil unless event&.timestamp

      Time.iso8601(event.timestamp)
    rescue ArgumentError
      nil
    end

    def duration_after_release(event, release)
      event_time_value = event_time(event)
      release_time = release&.time
      return "unknown" unless event_time_value && release_time

      seconds = [(event_time_value - release_time).to_i, 0].max
      if seconds < 60
        "#{seconds}s"
      elsif seconds < 3600
        "#{seconds / 60}m"
      elsif seconds < 86_400
        "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
      else
        "#{seconds / 86_400}d #{(seconds % 86_400) / 3600}h"
      end
    end

    def toggle_dual_screen
      if @dual_screen
        @dual_screen = false
        @clipboard_notice = "dual screen OFF"
      elsif @width < DUAL_SCREEN_MIN_WIDTH
        @clipboard_notice = "dual screen needs at least #{DUAL_SCREEN_MIN_WIDTH} columns"
      else
        @dual_screen = true
        @clipboard_notice = "dual screen ON · L copies LLM context"
      end
    end

    def copy_llm_context
      if copy_to_clipboard(llm_context_payload)
        @clipboard_notice = "copied redacted LLM context"
      else
        @clipboard_notice = "clipboard unavailable"
      end
    end

    def llm_context_payload
      scope = incident_source_events
      relevant = llm_context_events
      active_groups = error_groups.reject { |group| group[:muted] }.first(5)
      selected_release = @selected_event ? release_before_event(@selected_event) : @releases.last

      request_count = scope.count { |event| event.category == :router }
      error_count = scope.count { |event| active_error?(event) }
      muted_count = scope.count { |event| event.error? && muted_group?(event.error_group) }
      slow_count = scope.count { |event| event.service_ms && event.service_ms >= @slow_ms }

      lines = []
      lines << "TENTACLE DIAGNOSTIC CONTEXT"
      lines << "App: [REDACTED APP]"
      lines << "View: #{llm_view_label}"
      lines << "Incident: #{llm_incident_label}"
      lines << "Collected: #{@clock.call.utc.iso8601}"
      lines << "Search: #{@search.empty? ? '(none)' : redact_for_llm(@search)}"
      lines << "Slow threshold: #{@slow_ms}ms"
      lines << "Buffered scope: #{scope.length} lines | #{request_count} requests | #{error_count} errors | #{muted_count} muted errors | #{slow_count} slow requests"

      if selected_release
        release_time = selected_release.created_at.to_s.empty? ? "unknown time" : selected_release.created_at
        lines << "Release context: #{selected_release.version_label} | #{redact_for_llm(selected_release.description)} | #{selected_release.status} | #{release_time}"
      elsif @release_error
        lines << "Release context: unavailable (#{redact_for_llm(@release_error)})"
      else
        lines << "Release context: none returned"
      end

      lines << ""
      lines << "TOP ERROR GROUPS"
      if active_groups.empty?
        lines << "- none"
      else
        active_groups.each do |group|
          lines << "- #{group[:count]}x #{redact_for_llm(group[:label])}"
        end
      end

      if @selected_event
        event = @selected_event
        lines << ""
        lines << "SELECTED EVENT"
        lines << "Time: #{event.timestamp || '-'}"
        lines << "Source: #{event.source || '-'}"
        lines << "Process: #{event.process || '-'}"
        lines << "Database engine: #{event.database_label || '-'}"
        lines << "Status: #{event.status || '-'}"
        lines << "Method: #{event.method || '-'}"
        lines << "Path: #{event.path ? redact_for_llm(event.path) : '-'}"
        lines << "Service: #{event.service_ms ? "#{event.service_ms}ms" : '-'}"
        lines << "Request ID: #{event.request_id || '-'}"
        lines << "Error group: #{event.error_group ? redact_for_llm(event.error_group) : '-'}"
        lines << "Raw: #{redact_for_llm(event.raw)}"
      end

      lines << ""
      shown = relevant.last(LLM_LOG_LIMIT)
      lines << "RELEVANT LOGS (last #{shown.length} of #{relevant.length})"
      if shown.empty?
        lines << "(no matching log lines in this view)"
      else
        shown.each { |event| lines << redact_for_llm(event.raw) }
      end

      lines << ""
      lines << "REQUEST TO THE LLM"
      lines << "Analyze this Heroku diagnostic context. Identify the most likely root cause or causes, cite the evidence in the logs, and give the safest troubleshooting steps in priority order. Distinguish facts from guesses and call out any missing information needed to confirm the diagnosis."

      lines.join("\n")
    end

    def llm_context_events
      if groups_index? && @selected_group_key
        incident_source_events.select do |event|
          event.incident? || (event.error? && event.error_group == @selected_group_key)
        end
      elsif @detail_mode && @selected_event
        candidates = buffered_context(@selected_event, 3)
        if @selected_event.request_id
          candidates += incident_source_events.select { |event| event.raw.include?(@selected_event.request_id) }
        end
        candidates.uniq
      else
        filtered_events
      end
    end

    def llm_view_label
      return "Groups / #{@selected_group_key}" if groups_index? && @selected_group_key
      return "Groups / #{@group_occurrences_key}" if @tab == :groups && @group_occurrences_key
      return "Request #{@request_id}" if @tab == :request

      TABS.to_h.fetch(@tab, @tab.to_s.capitalize)
    end

    def llm_incident_label
      return "none" unless @incident_started_at

      state = incident_active? ? "active" : "stopped"
      ending = @incident_ended_at ? @incident_ended_at.iso8601 : "still running"
      scope = @incident_only ? "incident-only" : "all logs"
      "#{state} | #{@incident_started_at.iso8601} -> #{ending} | #{scope}"
    end

    def redact_for_llm(value)
      text = value.to_s.dup
      sensitive_keys = /password|passwd|secret(?:_key_base)?|token|api[_-]?key|access[_-]?key(?:_id)?|private[_-]?key|client[_-]?secret|authorization|cookie|session|database_url|redis_url/i

      text.gsub!(/(Bearer\s+)[A-Za-z0-9._~+\/=:-]+/i, '\\1[REDACTED]')
      text.gsub!(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, '[REDACTED_EMAIL]')
      text.gsub!(%r{(\b[a-z][a-z0-9+.-]*://)([^/\s:@]+):([^@\s/]+)@}i, '\\1[REDACTED]@')
      text.gsub!(/(["']?(?:#{sensitive_keys.source})["']?\s*[:=]\s*)(["'])(.*?)\2/i) do
        "#{Regexp.last_match(1)}#{Regexp.last_match(2)}[REDACTED]#{Regexp.last_match(2)}"
      end
      text.gsub!(/(["']?(?:#{sensitive_keys.source})["']?\s*[:=]\s*)([^\s,"';&]+)/i) do
        "#{Regexp.last_match(1)}[REDACTED]"
      end

      text
    end

    def copy_selected(mode)
      event = @selected_event
      return unless event

      text = if mode == :raw
        event.raw
      else
        event.request_id.to_s.empty? ? event.raw : event.request_id
      end

      if copy_to_clipboard(text)
        label = mode == :raw || event.request_id.to_s.empty? ? "raw line" : "request ID"
        @clipboard_notice = "copied #{label}"
      else
        @clipboard_notice = "clipboard unavailable"
      end
    end

    def copy_to_clipboard(text)
      if @clipboard_writer
        begin
          @clipboard_writer.call(text.to_s)
          return true
        rescue StandardError
          return false
        end
      end

      commands = [
        ["clip.exe"],        # WSL / Windows clipboard
        ["pbcopy"],          # macOS
        ["wl-copy"],         # Wayland
        ["xclip", "-selection", "clipboard"]
      ]

      commands.each do |command|
        next unless executable?(command.first)

        IO.popen(command, "w") { |io| io.write(text.to_s) }
        return true
      rescue StandardError
        next
      end

      false
    end

    def executable?(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, name)
        File.file?(path) && File.executable?(path)
      end
    end

    def build_styles
      adaptive = ->(light, dark) { Lipgloss::AdaptiveColor.new(light: light, dark: dark) }

      text = adaptive.call("#24292F", "#E6EDF3")
      muted = adaptive.call("#57606A", "#8B949E")
      blue = adaptive.call("#0969DA", "#79C0FF")
      purple = adaptive.call("#8250DF", "#D2A8FF")
      green = adaptive.call("#1A7F37", "#7EE787")
      red = adaptive.call("#CF222E", "#FF7B72")
      gold = adaptive.call("#9A6700", "#E3B341")
      surface = adaptive.call("#F6F8FA", "#161B22")
      surface_strong = adaptive.call("#EAEEF2", "#21262D")
      border = adaptive.call("#D0D7DE", "#30363D")
      white = adaptive.call("#FFFFFF", "#FFFFFF")
      dark_text = adaptive.call("#24292F", "#0D1117")

      @chart_colors = {
        requests: adaptive.call("#0969DA", "#58A6FF"),
        errors: adaptive.call("#CF222E", "#FF6B6B"),
        slow: adaptive.call("#9A6700", "#D29922")
      }

      @styles = {
        title: Lipgloss::Style.new.bold(true).foreground(white).background(adaptive.call("#6639BA", "#7C3AED")).padding(0, 1),
        app: Lipgloss::Style.new.bold(true).foreground(text),
        success_badge: Lipgloss::Style.new.bold(true).foreground(dark_text).background(adaptive.call("#2DA44E", "#3FB950")).padding(0, 1),
        info_badge: Lipgloss::Style.new.bold(true).foreground(white).background(adaptive.call("#0969DA", "#1F6FEB")).padding(0, 1),
        warning_badge: Lipgloss::Style.new.bold(true).foreground(dark_text).background(adaptive.call("#BF8700", "#D29922")).padding(0, 1),
        danger_badge: Lipgloss::Style.new.bold(true).foreground(white).background(adaptive.call("#CF222E", "#DA3633")).padding(0, 1),
        tab_active: Lipgloss::Style.new.bold(true).foreground(white).background(adaptive.call("#6639BA", "#5B5BD6")).padding(0, 1),
        tab_inactive: Lipgloss::Style.new.foreground(muted).padding(0, 1),
        tab_context: Lipgloss::Style.new.bold(true).foreground(blue).padding(0, 1),
        description: Lipgloss::Style.new.italic(true).foreground(muted),
        release_context: Lipgloss::Style.new.foreground(blue).background(surface),
        incident_context: Lipgloss::Style.new.bold(true).foreground(adaptive.call("#7D4E00", "#FFD8A8")).background(adaptive.call("#FFF8C5", "#2D1B00")),
        incident_context_active: Lipgloss::Style.new.bold(true).foreground(white).background(adaptive.call("#BC4C00", "#B54708")),
        search: Lipgloss::Style.new.foreground(text).background(surface),
        search_active: Lipgloss::Style.new.bold(true).foreground(white).background(adaptive.call("#0969DA", "#1F6FEB")),
        error: Lipgloss::Style.new.foreground(red),
        selected: Lipgloss::Style.new.bold(true).foreground(white).background(adaptive.call("#0969DA", "#1F6FEB")),
        footer: Lipgloss::Style.new.foreground(text).background(surface),
        muted: Lipgloss::Style.new.foreground(muted),
        section: Lipgloss::Style.new.bold(true).foreground(purple),
        chart_title: Lipgloss::Style.new.bold(true).foreground(text),
        chart_panel: Lipgloss::Style.new.border(:rounded).border_foreground(border).padding(0, 1),
        metric_neutral: Lipgloss::Style.new.foreground(text).background(surface_strong),
        metric_info: Lipgloss::Style.new.foreground(white).background(adaptive.call("#0969DA", "#1F6FEB")),
        metric_danger: Lipgloss::Style.new.foreground(white).background(adaptive.call("#CF222E", "#DA3633")),
        metric_warning: Lipgloss::Style.new.foreground(dark_text).background(adaptive.call("#BF8700", "#D29922")),
        metric_muted: Lipgloss::Style.new.foreground(text).background(adaptive.call("#D0D7DE", "#484F58")),
        release: Lipgloss::Style.new.bold(true).foreground(blue),
        incident_marker: Lipgloss::Style.new.bold(true).foreground(adaptive.call("#7D4E00", "#FFD8A8")).background(adaptive.call("#FFF8C5", "#2D1B00")),
        muted_error: Lipgloss::Style.new.foreground(muted),
        source_web: Lipgloss::Style.new.foreground(blue),
        source_worker: Lipgloss::Style.new.foreground(purple),
        source_postgres: Lipgloss::Style.new.foreground(gold),
        source_mysql: Lipgloss::Style.new.foreground(adaptive.call("#0550AE", "#56D4DD")),
        source_router: Lipgloss::Style.new.foreground(green),
        source_heroku: Lipgloss::Style.new.foreground(green),
        source_release: Lipgloss::Style.new.bold(true).foreground(blue)
      }
    end

    def styled(text, style)
      @color ? style.render(text.to_s) : text.to_s
    end

    def pad_between_ansi(left, right)
      left_width = ansi_width(left)
      right_width = ansi_width(right)
      spaces = [@width - left_width - right_width, 1].max
      left + (" " * spaces) + right
    end

    def ansi_width(text)
      if defined?(Lipgloss)
        Lipgloss.width(text.to_s)
      else
        strip_ansi(text.to_s).length
      end
    rescue StandardError
      strip_ansi(text.to_s).length
    end

    def field(name, value)
      "#{paint(name.ljust(12), DIM)} #{value || "-"}"
    end

    def wrap_text(text, width)
      return [""] if text.nil? || text.empty?

      text.scan(/.{1,#{[width, 1].max}}/)
    end

    def separator
      paint("─" * [@width, 1].max, DIM)
    end

    def truncate(text, width)
      return text if text.length <= width
      return text[0, width] if width < 2

      text[0, width - 1] + "…"
    end

    def truncate_ansi(text, width)
      return text if strip_ansi(text).length <= width

      # The tab row is short in normal terminals. If it overflows, dropping ANSI
      # and truncating is clearer than cutting in the middle of an escape code.
      truncate(strip_ansi(text), width)
    end

    def pad_between(left, right)
      visible_right = strip_ansi(right).length
      spaces = [@width - left.length - visible_right, 1].max
      truncate_ansi(left + (" " * spaces) + right, @width)
    end

    def paint(text, *codes)
      return text unless @color

      "#{codes.join}#{text}#{RESET}"
    end

    def strip_ansi(text)
      text.gsub(/\e\[[0-9;]*m/, "")
    end
  end
end
