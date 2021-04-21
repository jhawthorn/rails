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
          normalized_locals = normalize_locals(locals)

          # We need ||=, both to dedup on the normalized locals and to check
          # while holding the lock.
          @templates[normalized_locals] ||= build_template(normalized_locals)

          # This may have already been assigned, but we've already de-dup'd so
          # reassignment is fine.
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

      def normalize_locals(locals)
        locals.map(&:to_s).sort!.freeze
      end
  end
end
