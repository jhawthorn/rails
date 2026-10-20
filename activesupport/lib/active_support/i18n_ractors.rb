# :markup: markdown
# frozen_string_literal: true

require "i18n"

module ActiveSupport
  # The i18n gem keeps its settings in class variables, which non-main Ractors
  # can't read. Until it supports Ractors, `apply!` snapshots the settings,
  # translations and locale fallbacks from the main Ractor into a shareable
  # object, and makes `I18n.config` and `I18n.fallbacks` serve it.
  module I18nRactors # :nodoc:
    class Config < I18n::Config
      def initialize(snapshot)
        @snapshot = snapshot
        super()
      end

      def backend = @snapshot[:backend]
      def default_locale = @snapshot[:default_locale]
      def available_locales = @snapshot[:available_locales]
      def available_locales_set = @snapshot[:available_locales_set]
      def available_locales_initialized? = true
      def default_separator = @snapshot[:default_separator]
      def exception_handler = @snapshot[:exception_handler]
      def missing_interpolation_argument_handler = @snapshot[:missing_interpolation_argument_handler]
      def load_path = @snapshot[:load_path]
      def enforce_available_locales = @snapshot[:enforce_available_locales]
      def interpolation_patterns = @snapshot[:interpolation_patterns]
    end

    # Simple's translations are a Concurrent::Hash with a default proc, neither
    # of which can be shared.
    class Backend < I18n::Backend::Simple
      def initialize(translations)
        @translations = translations
        @initialized = true
      end

      def translations(do_init: false) = @translations
      def initialized? = true
      def reload! = self
    end

    class Fallbacks
      def initialize(map)
        @map = map
      end

      def [](locale) = @map.fetch(locale.to_sym) { [] }
    end

    module Accessors
      def config
        Thread.current[:active_support_i18n_ractors_config] ||= Config.new(I18nRactors.snapshot)
      end

      def config=(value)
        Thread.current[:active_support_i18n_ractors_config] = value
      end

      def fallbacks = I18nRactors.snapshot[:fallbacks]

      # The gem looks the pattern up in a Hash with a default proc.
      def interpolate_hash(string, values)
        pattern = I18nRactors.snapshot[:interpolation_pattern]
        interpolated = false

        interpolated_string = string.gsub(pattern) do |match|
          interpolated = true

          if match == "%%"
            "%"
          else
            key = ($1 || $2 || match.tr("%{}", "")).to_sym
            value = if values.key?(key)
              values[key]
            else
              config.missing_interpolation_argument_handler.call(key, values, string)
            end
            value = value.call(values) if value.respond_to?(:call)
            $3 ? sprintf("%#{$3}", value) : value
          end
        end

        interpolated ? interpolated_string : string
      end

      # The gem memoizes this in a class variable.
      def normalize_key(key, separator)
        case key
        when Array
          key.flat_map { |k| normalize_key(k, separator) }
        else
          key.to_s.split(separator).tap { |keys| keys.delete("") }.map! do |k|
            case k
            when /\A[-+]?([1-9]\d*|0)\z/ then k.to_i
            when "true" then true
            when "false" then false
            else k.to_sym
            end
          end
        end
      end
    end

    class << self
      attr_reader :snapshot

      def apply!
        return if @snapshot

        I18n.backend.send(:init_translations) unless I18n.backend.initialized?
        config = I18n.config

        @snapshot = Ractor.make_shareable({
          backend: Backend.new(plain_hash(I18n.backend.translations)),
          default_locale: config.default_locale,
          available_locales: config.available_locales,
          available_locales_set: config.available_locales_set,
          default_separator: config.default_separator,
          exception_handler: config.exception_handler,
          missing_interpolation_argument_handler: Ractor.shareable_lambda { |key, values, string|
            raise I18n::MissingInterpolationArgument.new(key, values, string)
          },
          load_path: config.load_path.map(&:to_s),
          enforce_available_locales: config.enforce_available_locales,
          interpolation_patterns: config.interpolation_patterns,
          interpolation_pattern: Regexp.union(config.interpolation_patterns),
          fallbacks: Fallbacks.new(fallbacks_map(config)),
        })

        I18n.singleton_class.prepend(Accessors)
        deprecated = Warning[:deprecated]
        Warning[:deprecated] = false # reading deprecated constants warns
        begin
          make_constants_shareable(I18n)
        ensure
          Warning[:deprecated] = deprecated
        end
        I18n.reserved_keys_pattern # memoized in a module instance variable
      end

      private
        # Constants such as I18n::RESERVED_KEYS are plain arrays and hashes.
        def make_constants_shareable(mod, seen = {}.compare_by_identity)
          return if seen[mod]
          seen[mod] = true

          mod.constants(false).each do |name|
            next if mod.autoload?(name)

            value = mod.const_get(name)
            if value.is_a?(Module)
              make_constants_shareable(value, seen) if value.name&.start_with?("I18n")
            elsif !Ractor.shareable?(value)
              Ractor.make_shareable(value) rescue nil
            end
          end
        end

        def plain_hash(hash)
          hash.to_h { |key, value| [key, value.is_a?(Hash) ? plain_hash(value) : value] }
        end

        def fallbacks_map(config)
          return {} unless I18n.respond_to?(:fallbacks)

          [*config.available_locales, config.default_locale].uniq.index_with do |locale|
            I18n.fallbacks[locale].dup
          end
        end
    end
  end
end
