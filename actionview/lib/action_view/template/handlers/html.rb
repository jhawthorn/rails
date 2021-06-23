# frozen_string_literal: true

module ActionView
  module Template::Handlers
    class Html < Raw
      def call(template, source)
        <<~RUBY
          buf = ActionView::OutputBuffer.new #{super}
          buf.close
          buf
        RUBY
      end
    end
  end
end
