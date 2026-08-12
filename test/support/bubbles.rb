# frozen_string_literal: true

module Bubbles
  module Spinners
    DOT = :dot
  end

  class Spinner
    attr_accessor :spinner

    def initialize
      @frame = 0
    end

    def tick = -> { TickMessage.new }

    def update(message)
      @frame = (@frame + 1) % 4 if message.is_a?(TickMessage)
      [self, message.is_a?(TickMessage) ? tick : nil]
    end

    def view
      %w[⠋ ⠙ ⠹ ⠸][@frame]
    end

    class TickMessage < Bubbletea::Message; end
  end

  class Viewport
    attr_accessor :width, :height, :content

    def initialize(width:, height:)
      @width = width
      @height = height
      @content = ""
      @offset = 0
    end

    def update(message)
      case message.to_s
      when "up", "k" then scroll_up(1)
      when "down", "j" then scroll_down(1)
      when "pgup" then page_up
      when "pgdown" then page_down
      when "home", "g" then goto_top
      when "end", "G" then goto_bottom
      end
      [self, nil]
    end

    def scroll_up(n = 1) = (@offset = [@offset - n, 0].max)
    def scroll_down(n = 1) = (@offset = [@offset + n, max_offset].min)
    def page_up = scroll_up([@height - 1, 1].max)
    def page_down = scroll_down([@height - 1, 1].max)
    def goto_top = (@offset = 0)
    def goto_bottom = (@offset = max_offset)
    def scroll_percent = max_offset.zero? ? 0.0 : @offset.to_f / max_offset
    def at_top? = @offset.zero?
    def at_bottom? = @offset >= max_offset

    def view
      lines = @content.to_s.split("\n", -1)
      (lines[@offset, @height] || []).map { |line| line[0, @width] }.join("\n")
    end

    private

    def max_offset
      [[@content.to_s.split("\n", -1).length - @height, 0].max, 0].max
    end
  end

  class Help
    def short_help_view(bindings)
      bindings.map { |binding| binding.help.join(" ") }.join(" · ")
    end
  end

  module Key
    Binding = Struct.new(:keys, :help, keyword_init: true)

    def self.binding(keys:, help:)
      Binding.new(keys: keys, help: help)
    end

    def self.matches?(message, binding)
      binding.keys.include?(message.to_s)
    end
  end
end
