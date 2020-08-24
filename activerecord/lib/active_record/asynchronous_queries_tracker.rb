# frozen_string_literal: true

require "weakref"

module ActiveRecord
  class AsynchronousQueriesTracker # :nodoc:
    class << self
      def install_executor_hooks(executor = ActiveSupport::Executor)
        executor.register_hook(self)
      end

      def run
        ActiveRecord::Base.asynchronous_queries_tracker
      end

      def complete(asynchronous_queries_tracker)
        asynchronous_queries_tracker.finalize
      end
    end

    def initialize
      @current_queries = nil
    end

    def register(future_result)
      current_queries[future_result] = future_result
    end

    # This should be called from a request/job middleware to cancel all queries that might not have been used
    def finalize
      if queries = reset!
        queries.each_value(&:cancel!)
      end
    end

    private
      def reset!
        queries = @current_queries
        @current_queries = nil
        queries
      end

      def current_queries
        @current_queries ||= ObjectSpace::WeakMap.new
      end
  end
end
