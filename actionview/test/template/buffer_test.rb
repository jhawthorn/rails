# frozen_string_literal: true

require "abstract_unit"

class BufferTest < ActionView::TestCase
  def test_deferred_buffer
    outer_buffer = ActionView::OutputBuffer.new
    inner_buffer = ActionView::OutputBuffer.new

    outer_buffer << "HELLO "
    outer_buffer << inner_buffer
    outer_buffer << "!"

    inner_buffer << "WORLD"

    inner_buffer.close
    outer_buffer.close

    assert_equal "HELLO WORLD!", outer_buffer.to_s
  end
end
