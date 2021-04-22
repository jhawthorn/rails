# frozen_string_literal: true

require "pathname"
require "active_support/core_ext/class"
require "active_support/core_ext/module/attribute_accessors"
require "action_view/template"
require "thread"
require "concurrent/map"

module ActionView
  # = Action View Resolver
  class Resolver
    # Keeps all information about view path and builds virtual path.
    class Path
      attr_reader :name, :prefix, :partial, :virtual
      alias_method :partial?, :partial

      def self.virtual(name, prefix, partial)
        if prefix.empty?
          "#{partial ? "_" : ""}#{name}"
        elsif partial
          "#{prefix}/_#{name}"
        else
          "#{prefix}/#{name}"
        end
      end

      def self.build(name, prefix, partial)
        new name, prefix, partial, virtual(name, prefix, partial)
      end

      def initialize(name, prefix, partial, virtual)
        @name    = name
        @prefix  = prefix
        @partial = partial
        @virtual = virtual
      end

      def to_str
        @virtual
      end
      alias :to_s :to_str
    end

    TemplateDetails = Struct.new(:path, :locale, :handler, :format, :variant)

    class PathParser # :nodoc:
      def build_path_regex
        handlers = Template::Handlers.extensions.map { |x| Regexp.escape(x) }.join("|")
        formats = Template::Types.symbols.map { |x| Regexp.escape(x) }.join("|")
        locales = "[a-z]{2}(?:-[A-Z]{2})?"
        variants = "[^.]*"

        %r{
          \A
          (?:(?<prefix>.*)/)?
          (?<partial>_)?
          (?<action>.*?)
          (?:\.(?<locale>#{locales}))??
          (?:\.(?<format>#{formats}))??
          (?:\+(?<variant>#{variants}))??
          (?:\.(?<handler>#{handlers}))?
          \z
        }x
      end

      def parse(path)
        @regex ||= build_path_regex
        match = @regex.match(path)
        path = Path.build(match[:action], match[:prefix] || "", !!match[:partial])
        TemplateDetails.new(
          path,
          match[:locale]&.to_sym,
          match[:handler]&.to_sym,
          match[:format]&.to_sym,
          match[:variant]
        )
      end
    end

    cattr_accessor :caching, default: true

    class << self
      alias :caching? :caching
    end

    def initialize
    end

    def clear_cache
    end

    # Normalizes the arguments and passes it on to find_templates.
    def find_all(name, prefix = nil, partial = false, details = {}, key = nil, locals = [])
      locals = locals.map(&:to_s).sort!.freeze
      _find_all(name, prefix, partial, details, key, locals)
    end

    def all_template_paths # :nodoc:
      # Not implemented by default
      []
    end

  private
    def _find_all(name, prefix, partial, details, key, locals)
      find_templates(name, prefix, partial, details, locals)
    end

    delegate :caching?, to: :class

    # This is what child classes implement. No defaults are needed
    # because Resolver guarantees that the arguments are present and
    # normalized.
    def find_templates(name, prefix, partial, details, locals = [])
      raise NotImplementedError, "Subclasses must implement a find_templates(name, prefix, partial, details, locals = []) method"
    end

    # Handles templates caching. If a key is given and caching is on
    # always check the cache before hitting the resolver. Otherwise,
    # it always hits the resolver but if the key is present, check if the
    # resolver is fresher before returning it.
    def cached(key, path_info, details, locals)
      name, prefix, partial = path_info

      if key
        @cache.cache(key, name, prefix, partial, locals) do
          yield
        end
      else
        yield
      end
    end
  end

  # A resolver that loads files from the filesystem.
  class FileSystemResolver < Resolver
    attr_reader :path

    def initialize(path)
      raise ArgumentError, "path already is a Resolver class" if path.is_a?(Resolver)
      @unbound_templates = Concurrent::Map.new
      @path_parser = PathParser.new
      @path = File.expand_path(path)
      super()
    end

    def clear_cache
      @unbound_templates.clear
      @path_parser = PathParser.new
      super
    end

    def to_s
      @path.to_s
    end
    alias :to_path :to_s

    def eql?(resolver)
      self.class.equal?(resolver.class) && to_path == resolver.to_path
    end
    alias :== :eql?

    def all_template_paths # :nodoc:
      paths = template_glob("**/*")
      paths.map do |filename|
        filename.from(@path.size + 1).remove(/\.[^\/]*\z/)
      end.uniq
    end

    private
      def _find_all(name, prefix, partial, details, key, locals)
        virtual = Path.virtual(name, prefix, partial)
        cache = key ? @unbound_templates : Concurrent::Map.new

        unbound_templates =
          cache.compute_if_absent(virtual) do
            path = Path.new(name, prefix, partial, virtual)
            unbound_templates_from_path(path)
          end

        filter_and_sort_by_details(unbound_templates, details).map! do |unbound_template|
          unbound_template.bind_locals(locals)
        end
      end

      def source_for_template(template)
        Template::Sources::File.new(template)
      end

      def build_unbound_template(template)
        details = @path_parser.parse(template.from(@path.size + 1))
        source = source_for_template(template)

        UnboundTemplate.new(
          source,
          template,
          details.handler,
          virtual_path: details.path.virtual,
          locale: details.locale,
          format: details.format,
          variant: details.variant,
        )
      end

      def unbound_templates_from_path(path)
        if path.name.include?(".")
          return []
        end

        # Instead of checking for every possible path, as our other globs would
        # do, scan the directory for files with the right prefix.
        paths = template_glob("#{escape_entry(path.to_s)}*")

        paths.map do |path|
          build_unbound_template(path)
        end.select do |template|
          # Select for exact virtual path match, including case sensitivity
          template.virtual_path == path.virtual
        end
      end

      def filter_and_sort_by_details(templates, details)
        return templates if templates.empty?

        locale = details[:locale]
        formats = details[:formats]
        variants = details[:variants]
        handlers = details[:handlers]

        templates =
          templates.select do |template|
            if (!template.locale || locale.include?(template.locale)) &&
                (!template.format || formats.include?(template.format)) &&
                (!template.variant || variants == :any || variants.include?(template.variant.to_sym)) &&
                (!template.handler || handlers.include?(template.handler))
              templates
            end
          end

        return templates if templates.size <= 1

        templates.sort_by! do |template|
          [
            details_match_sort_key(template.locale, locale),
            details_match_sort_key(template.format, formats),
            if variants == :any
              template.variant ? 1 : 0
            else
              details_match_sort_key(template.variant&.to_sym, variants)
            end,
            details_match_sort_key(template.handler, handlers)
          ]
        end

        templates
      end

      def details_match_sort_key(have, want)
        if have
          want.index(have)
        else
          want.size
        end
      end

      # Safe glob within @path
      def template_glob(glob)
        query = File.join(escape_entry(@path), glob)
        path_with_slash = File.join(@path, "")

        Dir.glob(query).reject do |filename|
          File.directory?(filename)
        end.map do |filename|
          File.expand_path(filename)
        end.select do |filename|
          filename.start_with?(path_with_slash)
        end
      end

      def escape_entry(entry)
        entry.gsub(/[*?{}\[\]]/, '\\\\\\&')
      end
  end
end
