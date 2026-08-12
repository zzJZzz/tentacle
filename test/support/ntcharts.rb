# frozen_string_literal: true

module Ntcharts
  class Sparkline
    attr_accessor :style

    def initialize(width, height)
      @width = width
      @height = height
      @values = []
    end

    def push(value) = @values << value
    def draw_braille = self

    def view
      values = @values.last(@width)
      return " " * @width if values.empty?
      max = [values.max.to_f, 1.0].max
      runes = %w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █]
      line = values.map { |v| runes[((v.to_f / max) * (runes.length - 1)).round] }.join
      line.ljust(@width)
    end
  end
end
