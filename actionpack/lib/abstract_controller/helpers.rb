# frozen_string_literal: true

require "active_support/dependencies"

module AbstractController
  module Helpers
    extend ActiveSupport::Concern

    included do
      class_attribute :_helpers, default: define_helpers_module(self)
      class_attribute :_helper_methods, default: Array.new
      @_helpers_has_been_set = true
    end

    class MissingHelperError < LoadError
      def initialize(error, path)
        @error = error
        @path  = "helpers/#{path}.rb"
        set_backtrace error.backtrace

        if /^#{path}(\.rb)?$/.match?(error.path)
          super("Missing helper file helpers/%s.rb" % path)
        else
          raise error
        end
      end
    end

    module ClassMethods
      # When a class is inherited, wrap its helper module in a new module.
      # This ensures that the parent class's module can be changed
      # independently of the child class's.
      def inherited(klass)
        klass.redefine_singleton_method(:_helpers) do
          @_helpers_has_been_accessed = caller
          super().freeze
          #superclass._helpers
        end
        klass.class_eval { default_helper_module! } unless klass.anonymous?
        super
      end

      # Declare a controller method as a helper. For example, the following
      # makes the +current_user+ and +logged_in?+ controller methods available
      # to the view:
      #   class ApplicationController < ActionController::Base
      #     helper_method :current_user, :logged_in?
      #
      #     def current_user
      #       @current_user ||= User.find_by(id: session[:user])
      #     end
      #
      #     def logged_in?
      #       current_user != nil
      #     end
      #   end
      #
      # In a view:
      #  <% if logged_in? -%>Welcome, <%= current_user.name %><% end -%>
      #
      # ==== Parameters
      # * <tt>method[, method]</tt> - A name or names of a method on the controller
      #   to be made available on the view.
      def helper_method(*methods)
        methods.flatten!
        self._helper_methods += methods

        location = caller_locations(1, 1).first
        file, line = location.path, location.lineno

        methods.each do |method|
          _helpers_for_modification.class_eval <<-ruby_eval, file, line
            def #{method}(*args, &block)                    # def current_user(*args, &block)
              controller.send(:'#{method}', *args, &block)  #   controller.send(:'current_user', *args, &block)
            end                                             # end
            ruby2_keywords(:'#{method}') if respond_to?(:ruby2_keywords, true)
          ruby_eval
        end
      end

      # Includes the given modules in the template class.
      #
      # Modules can be specified in different ways. All of the following calls
      # include +FooHelper+:
      #
      #   # Module, recommended.
      #   helper FooHelper
      #
      #   # String/symbol without the "helper" suffix, camel or snake case.
      #   helper "Foo"
      #   helper :Foo
      #   helper "foo"
      #   helper :foo
      #
      # The last two assume that <tt>"foo".camelize</tt> returns "Foo".
      #
      # When strings or symbols are passed, the method finds the actual module
      # object using +String#constantize+. Therefore, if the module has not been
      # yet loaded, it has to be autoloadable, which is normally the case.
      #
      # Namespaces are supported. The following calls include +Foo::BarHelper+:
      #
      #   # Module, recommended.
      #   helper Foo::BarHelper
      #
      #   # String/symbol without the "helper" suffix, camel or snake case.
      #   helper "Foo::Bar"
      #   helper :"Foo::Bar"
      #   helper "foo/bar"
      #   helper :"foo/bar"
      #
      # The last two assume that <tt>"foo/bar".camelize</tt> returns "Foo::Bar".
      #
      # The method accepts a block too. If present, the block is evaluated in
      # the context of the controller helper module. This simple call makes the
      # +wadus+ method available in templates of the enclosing controller:
      #
      #   helper do
      #     def wadus
      #       "wadus"
      #     end
      #   end
      #
      # Furthermore, all the above styles can be mixed together:
      #
      #   helper FooHelper, "woo", "bar/baz" do
      #     def wadus
      #       "wadus"
      #     end
      #   end
      #
      def helper(*args, &block)
        modules_for_helpers(args).each do |mod|
          _helpers_for_modification.include(mod)
        end

        _helpers_for_modification.module_eval(&block) if block_given?
      end

      # Clears up all existing helpers in this class, only keeping the helper
      # with the same name as this class.
      def clear_helpers
        inherited_helper_methods = _helper_methods
        self._helpers = Module.new
        self._helper_methods = Array.new

        inherited_helper_methods.each { |meth| helper_method meth }
        default_helper_module! unless anonymous?
      end

      # Given an array of values like the ones accepted by +helper+, this method
      # returns an array with the corresponding modules, in the same order.
      def modules_for_helpers(modules_or_helper_prefixes)
        modules_or_helper_prefixes.flatten.map! do |module_or_helper_prefix|
          case module_or_helper_prefix
          when Module
            module_or_helper_prefix
          when String, Symbol
            helper_prefix = module_or_helper_prefix.to_s
            helper_prefix = helper_prefix.camelize unless helper_prefix.start_with?(/[A-Z]/)
            "#{helper_prefix}Helper".constantize
          else
            raise ArgumentError, "helper must be a String, Symbol, or Module"
          end
        end
      end

      def _helpers_for_modification
        # Check if we have built a helper unique to this class, if not, we
        # must build one
        @_helpers_has_been_set ||= nil

        unless @_helpers_has_been_set
          @_helpers_has_been_accessed ||= nil
          if @_helpers_has_been_accessed
            raise "_helpers has already been accessed at: #{@_helpers_has_been_accessed.join("\n")}"
          end
          self._helpers = define_helpers_module(self, superclass._helpers)
        end
        @_helpers_has_been_set = true
        _helpers
      end

      private
        def define_helpers_module(klass, helpers = nil)
          # In some tests inherited is called explicitly. In that case, just
          # return the module from the first time it was defined
          return klass.const_get(:HelperMethods) if klass.const_defined?(:HelperMethods, false)

          mod = Module.new
          klass.const_set(:HelperMethods, mod)
          mod.include(helpers) if helpers
          mod
        end

        def default_helper_module!
          helper_prefix = name.delete_suffix("Controller")
          helper(helper_prefix)
        rescue NameError => e
          raise unless e.missing_name?("#{helper_prefix}Helper")
        end
    end
  end
end
