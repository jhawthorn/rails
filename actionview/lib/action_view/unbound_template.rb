# frozen_string_literal: true

# :markup: markdown

module ActionView
  class UnboundTemplate
    attr_reader :virtual_path, :details
    delegate :locale, :format, :variant, :handler, to: :@details

    def initialize(source, identifier, details:, virtual_path:)
      @source = source
      @identifier = identifier
      @details = details
      @virtual_path = virtual_path

      @template = nil
      @write_lock = Mutex.new
    end

    # Locals no longer affect the compiled template: non-strict templates read
    # them dynamically from +local_assigns+ and strict locals templates declare
    # them in the template itself. The argument is accepted for compatibility
    # and ignored.
    def bind_locals(_locals = nil)
      @template || @write_lock.synchronize { @template ||= build_template }
    end

    def built_templates # :nodoc:
      @template ? [@template] : []
    end

    def freeze # :nodoc:
      bind_locals.freeze
      @source.freeze
      @identifier.freeze
      @virtual_path.freeze
      @details.freeze
      @write_lock = nil
      super
    end

    private
      def build_template
        Template.new(
          @source,
          @identifier,
          details.handler_class,

          format: details.format_or_default,
          variant: variant&.to_s,
          virtual_path: @virtual_path,

          locals: [].freeze
        )
      end
  end
end
