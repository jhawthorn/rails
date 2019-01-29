# frozen_string_literal: true

require "active_record/middleware/database_selector/resolver"

module ActiveRecord
  module Middleware
    # The DatabaseSelector Middleware provides a framework for automatically
    # swapping from the primary to the replica. Rails provides a basic class
    # that determines when to swap and allows for those classes to be replaced
    # to support your application.
    #
    # The resolver class defines when the application should switch (i.e. read
    # from the primary if a write occurred less than 5 seconds ago) and an
    # operations class that sets a value that helps the resolver class decide
    # when to switch.
    #
    # Rails default middleware uses the request's session to set timestamps
    # that inform the application when to read from a primary or read from a
    # replica.
    #
    # To use the DatabaseSelector in your application include the middleware:
    #
    #   config.middleware.use ActiveRecord::Middleware::DatabaseSelector
    #
    # To define your own resolver and or operations class pass those classes
    # into the middleware:
    #
    #     config.middleware.use ActiveRecord::Middleware::DatabaseSelector,
    #       MyResolverClass, MyOperationsClass
    #
    # This makes it easy for an application to define a different way of
    # switching connections, for example, by setting a cookie or using a token.
    #
    # The session operations class that Rails provides is meant to be an example
    # of the basic requirements for automatic database switching and is not
    # recommended for use in production. Once you have an understanding of
    # how your replication strategy works your application should implement
    # it's own operations class, even if that operations class uses Sessions.
    #
    # For example you may want to calculate replication lag in addition to
    # calculating time since last write. To do this in your application should
    # implement it's own Session class (or whatever operations you choose)
    # that calculates that lag and returns true/false whether it's safe to read
    # from the replicas.
    class DatabaseSelector
      def initialize(app, resolver_klass = Resolver, operations_klass = Resolver::Session)
        @app = app
        @resolver_klass = resolver_klass
        @operations_klass = operations_klass
      end

      attr_reader :resolver_klass, :operations_klass

      # Middleware that decides which database connection to use in a mutliple
      # database application.
      def call(env)
        request = ActionDispatch::Request.new(env)

        select_database(request) do
          @app.call(env)
        end
      end

      private

        def select_database(request, &blk)
          operations = operations_klass.call(request)
          database_resolver = resolver_klass.call(operations)

          if reading_request?(request)
            database_resolver.read(&blk)
          else
            database_resolver.write(&blk)
          end
        end

        def reading_request?(request)
          request.get? || request.head?
        end
    end
  end
end
