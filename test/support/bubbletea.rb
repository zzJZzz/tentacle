# frozen_string_literal: true

module Bubbletea
  module Model; end

  class Message; end

  class KeyMessage < Message
    KEY_RUNES = -1
    KEY_ENTER = 13
    KEY_ESC = 27
    KEY_BACKSPACE = 127
    KEY_SPACE = -25

    attr_reader :key_type, :runes

    def initialize(name, key_type: nil, runes: nil)
      @name = name
      @key_type = key_type || infer_type(name)
      @runes = runes || infer_runes(name)
    end

    def to_s = @name
    def runes? = @key_type == KEY_RUNES
    def char
      @runes.pack("U*") unless @runes.empty?
    end
    def space? = @key_type == KEY_SPACE || @name == "space"

    private

    def infer_type(name)
      case name
      when "enter" then KEY_ENTER
      when "esc" then KEY_ESC
      when "backspace" then KEY_BACKSPACE
      when "space" then KEY_SPACE
      else KEY_RUNES
      end
    end

    def infer_runes(name)
      name.length == 1 ? [name.ord] : []
    end
  end

  class MouseMessage < Message
    BUTTON_LEFT = 1
    BUTTON_WHEEL_UP = 4
    BUTTON_WHEEL_DOWN = 5
    ACTION_PRESS = 0
    ACTION_RELEASE = 1
    ACTION_MOTION = 2

    attr_reader :x, :y, :button, :action

    def initialize(x:, y:, button:, action:)
      @x = x
      @y = y
      @button = button
      @action = action
    end

    def press? = @action == ACTION_PRESS
    def release? = @action == ACTION_RELEASE
    def wheel? = @button >= BUTTON_WHEEL_UP
    def left? = @button == BUTTON_LEFT
  end

  class WindowSizeMessage < Message
    attr_reader :width, :height
    def initialize(width:, height:)
      @width = width
      @height = height
    end
  end

  class QuitCommand; end
  def self.quit = QuitCommand.new

  class BatchCommand
    attr_reader :commands
    def initialize(commands) = (@commands = commands.compact)
  end
  def self.batch(*commands) = BatchCommand.new(commands)
end
