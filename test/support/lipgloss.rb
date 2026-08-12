# frozen_string_literal: true

module Lipgloss

  class AdaptiveColor
    attr_reader :light, :dark
    def initialize(light:, dark:)
      @light = light
      @dark = dark
    end
  end
  class Style
    def initialize
      @width = nil
    end

    def method_missing(name, *args)
      @width = args.first if name == :width
      self
    end

    def respond_to_missing?(_name, _include_private = false) = true

    def render(text)
      text.to_s
    end
  end

  def self.width(text)
    text.to_s.gsub(/\e\[[0-9;]*m/, "").length
  end

  def self.join_horizontal(_position, *strings)
    parts = strings.map { |s| s.to_s.split("\n", -1) }
    height = parts.map(&:length).max || 0
    widths = parts.map { |lines| lines.map(&:length).max || 0 }
    Array.new(height) do |row|
      parts.each_with_index.map { |lines, i| (lines[row] || "").ljust(widths[i]) }.join
    end.join("\n")
  end
end
