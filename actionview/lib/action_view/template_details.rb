module ActionView
  class TemplateDetails
    attr_reader :locale, :handler, :format, :variant

    def initialize(locale, handler, format, variant)
      @locale = locale
      @handler = handler
      @format = format
      @variant = variant
    end
  end
end
