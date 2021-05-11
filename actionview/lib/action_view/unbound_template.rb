# frozen_string_literal: true

require "concurrent/map"

module ActionView
  class UnboundTemplate
    attr_reader :virtual_path, :details
    delegate :locale, :format, :variant, :handler, to: :@details

    def initialize(source, identifier, details:, virtual_path:)
      @source = source
      @identifier = identifier
      @details = details
      @virtual_path = virtual_path

      @templates = Concurrent::Map.new(initial_capacity: 2)
    end

    def bind_locals(locals)
      @templates[locals] ||= build_template(locals)
    end

    private
      def build_template(locals)
        handler_class = Template.handler_for_extension(handler)
        format = self.format || handler_class.try(:default_format)

        Template.new(
          @source,
          @identifier,
          handler_class,

          format: format,
          variant: variant&.to_s,
          virtual_path: @virtual_path,

          locals: locals
        )
      end
  end
end
