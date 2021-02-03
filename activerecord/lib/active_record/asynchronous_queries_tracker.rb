# frozen_string_literal: true

require "weakref"

module ActiveRecord
  class AsynchronousQueriesTracker # :nodoc:
    class << self
      def install_executor_hooks(executor = ActiveSupport::Executor)
        executor.register_hook(self)
      end

      def run
        reset!
      end

      def complete(asynchronous_queries_tracker)
        asynchronous_queries_tracker.finalize
        reset!
      end

      private

        def reset!
          ActiveRecord::Base.asynchronous_queries_tracker = new
        end
    end

    def initialize
      @running = Concurrent::AtomicBoolean.new(true)
    end

    def running?
      @running.true?
    end

    # This should be called from a request/job middleware to cancel all queries that might not have been used
    def finalize
      @running.make_false
    end
  end
end
