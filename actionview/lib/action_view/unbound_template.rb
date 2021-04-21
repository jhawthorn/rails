# frozen_string_literal: true

require "concurrent/map"

module ActionView
  class UnboundTemplate
    attr_reader :handler, :format, :variant, :locale, :virtual_path

    def initialize(source, identifier, handler, format:, variant:, locale:, virtual_path:)
      @source = source
      @identifier = identifier
      @handler = handler

      @format = format
      @variant = variant
      @locale = locale
      @virtual_path = virtual_path

      @write_lock = Mutex.new
      @templates = {}
    end

    def bind_locals(locals)
      if template = @templates[locals]
        template
      else
        @write_lock.synchronize do
          # De-dup same locals in a different order
          normalized_locals = locals.map(&:to_s).sort!.freeze
          @templates[normalized_locals] ||= build_template(locals)

          # locals may be the same as normalized locals. That's fine
          @templates[locals] = @templates[normalized_locals]
        end
      end
    end

    private
      def build_template(locals)
        handler = Template.handler_for_extension(@handler)
        format = @format || handler.try(:default_format)

        Template.new(
          @source,
          @identifier,
          handler,

          format: format,
          variant: @variant,
          virtual_path: @virtual_path,

          locals: locals
        )
      end
  end
end
