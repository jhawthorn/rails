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

    def initialize(string = "")
      @array = [[:raw, string]]
      @encoding = string.encoding
    end

    def <<(value)
      @array << [:raw, value]
    end
    alias :concat  :<<
    alias :append= :<<

    def safe_concat(value)
      @array << [:safe, value]
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

    def length
      @array.sum(&:length)
    end

    def empty?
      @array.all? {|_,s| s.empty? }
    end

    def blank?
      @array.all? {|_,s| s.blank? }
    end

    def to_s
      @array.map do |type, value|
        case type
        when :safe
          value.to_s
        when :raw
          value = value.to_s
          value = ERB::Util.h(value) unless value.html_safe?
          value
        end
      end.join.html_safe
    end

    def html_safe?
      true
    end

    def html_safe
      self
    end
  end
  DeferredBuffer = OutputBuffer
end
