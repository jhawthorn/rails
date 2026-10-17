# frozen_string_literal: true

# :markup: markdown
module ActionView # :nodoc:
  module PathRegistry # :nodoc:
    @view_paths_by_class = {}
    @file_system_resolvers = {}
    @file_system_resolver_mutex = Mutex.new
    @file_system_resolver_hooks = []

    class << self
      attr_reader :file_system_resolver_hooks
    end

    def self.get_view_paths(klass)
      @view_paths_by_class[klass] || get_view_paths(klass.superclass)
    end

    def self.set_view_paths(klass, paths)
      @view_paths_by_class[klass] = paths
    end

    def self.cast_file_system_resolvers(paths)
      paths = Array(paths)

      @file_system_resolver_mutex.synchronize do
        built_resolver = false
        paths = paths.map do |path|
          case path
          when String, Pathname
            path = File.expand_path(path)
            @file_system_resolvers[path] ||=
              begin
                built_resolver = true
                FileSystemResolver.new(path)
              end
          else
            path
          end
        end

        file_system_resolver_hooks.each(&:call) if built_resolver
      end

      paths
    end

    def self.all_resolvers
      resolvers = [all_file_system_resolvers]
      resolvers.concat @view_paths_by_class.values.map(&:to_a)
      resolvers.flatten.uniq
    end

    def self.all_file_system_resolvers
      @file_system_resolvers.values
    end

    # Loads and compiles every template in the registered file system view
    # paths, so that no template has to be compiled while handling a request
    # and a template that can't be compiled fails at boot rather than on the
    # first request that renders it.
    #
    # Templates compile into the view context class shared by every
    # controller and mailer, so they are usable from any of them.
    def self.eager_load_templates!(view = compile_view) # :nodoc:
      all_file_system_resolvers.each do |resolver|
        resolver.eager_load_templates(view)
      end
    end

    def self.make_shareable! # :nodoc:
      eager_load_templates!
      all_file_system_resolvers.each(&:freeze)

      @file_system_resolver_mutex.synchronize { Ractor.make_shareable(@file_system_resolvers) }
      Ractor.make_shareable(@view_paths_by_class)
    end

    def self.compile_view
      ActionView::LookupContext.view_context_class.new(ActionView::LookupContext.new([]), {}, nil)
    end
    private_class_method :compile_view
  end
end
