# frozen_string_literal: true

require "active_support/core_ext/string/output_safety"

module ActionView
  # Used as a buffer for views
  #
  # The main difference between this and ActiveSupport::SafeBuffer
  # is for the methods `<<` and `safe_expr_append=` the inputs are
  # checked for nil before they are assigned and `to_s` is called on
  # the input. For example:
  #
  #   obuf = ActionView::OutputBuffer.new "hello"
  #   obuf << 5
  #   puts obuf # => "hello5"
  #
  #   sbuf = ActiveSupport::SafeBuffer.new "hello"
  #   sbuf << 5
  #   puts sbuf # => "hello\u0005"
  #
  #class OutputBuffer < ActiveSupport::SafeBuffer #:nodoc:
  #  def initialize(*)
  #    super
  #    encode!
  #  end

  #  def <<(value)
  #    return self if value.nil?
  #    super(value.to_s)
  #  end
  #  alias :append= :<<

  #  def safe_expr_append=(val)
  #    return self if val.nil?
  #    safe_concat val.to_s
  #  end

  #  alias :safe_append= :safe_concat
  #end

  class StreamingBuffer #:nodoc:
    def initialize(block)
      @block = block
    end

    def encoding
      Encoding.default_internal
    end

    def <<(value)
      value = value.to_s
      value = ERB::Util.h(value) unless value.html_safe?
      @block.call(value)
    end
    alias :concat  :<<
    alias :append= :<<

    def safe_concat(value)
      @block.call(value.to_s)
    end
    alias :safe_append= :safe_concat

    def html_safe?
      true
    end

    def html_safe
      self
    end
  end

  class OutputBuffer #:nodoc:
    attr_reader :encoding

    class RawValue
      def initialize(value)
        @value = value
      end

      def empty?
        @value.empty?
      end

      def blank?
        @value.blank?
      end

      def to_s
        value = @value.to_s
        value = ERB::Util.h(value) unless value.html_safe?
        value
      end
    end

    def initialize(string = "")
      @array = [RawValue.new(string)]
      @encoding = string.encoding
    end

    def <<(value)
      @array << RawValue.new(value)
    end
    alias :concat  :<<
    alias :append= :<<

    def safe_concat(value)
      @array << value
    end
    alias :safe_append= :safe_concat

    def safe_expr_append=(val)
      return self if val.nil?
      safe_concat val
    end

    def stream_to(ob)
      ob.safe_concat(to_s)
      @array.clear
      nil
    end

    def empty?
      @array.all?(&:empty?)
    end

    def blank?
      @array.all?(&:blank?)
    end

    def close
      @array.freeze
      @to_s = _build_string
    end

    def freeze
      close
      super
    end

    def closed?
      defined?(@to_s)
    end

    def to_s
      return @to_s if closed?
      #ActiveSupport::Deprecation.warn("output_buffer must be closed before calling to_s")
      raise "to_s on open output_buffer"
      _build_string
    end

    def _build_string
      @array.map(&:to_s).join.html_safe
    end

    alias to_str to_s

    def html_safe?
      true
    end

    def html_safe
      self
    end
  end
  DeferredBuffer = OutputBuffer
end
