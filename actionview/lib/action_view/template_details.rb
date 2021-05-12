module ActionView
  class TemplateDetails # :nodoc:
    attr_reader :locale, :handler, :format, :variant

    def initialize(locale, handler, format, variant)
      @locale = locale
      @handler = handler
      @format = format
      @variant = variant
    end

    def sort_key_for(requested_details)
      requested_locale   = requested_details[:locale]
      requested_formats  = requested_details[:formats]
      requested_variants = requested_details[:variants]
      requested_handlers = requested_details[:handlers]

      locale_match = details_match_sort_key(locale, requested_locale) || return
      format_match = details_match_sort_key(format, requested_formats) || return
      variant_match =
        if requested_variants == :any
          variant ? 1 : 0
        else
          details_match_sort_key(variant, requested_variants) || return
        end
      handler_match = details_match_sort_key(handler, requested_handlers) || return

      [locale_match, format_match, variant_match, handler_match]
    end

    def handler_class
      Template.handler_for_extension(handler)
    end

    def format_or_default
      format || handler_class.try(:default_format)
    end

    private

      def details_match_sort_key(have, want)
        if have
          want.index(have)
        else
          want.size
        end
      end
  end
end
