# frozen_string_literal: true

module ActiveRecord
  class FutureResult
    Canceled = Class.new(ActiveRecordError)

    delegate :empty?, :to_a, to: :result!

    def initialize(pool, *args, **kwargs)
      @mutex = Mutex.new

      @pool = pool
      @args = args
      @kwargs = kwargs

      @executed = false
      @error = nil
      @result = nil

      @async_query_tracker = ActiveRecord::Base.asynchronous_queries_tracker
    end

    def schedule!
      return unless @async_query_tracker.running?
      @pool.schedule_query(self)
    end

    def execute!(connection)
      execute_query(connection)
    end

    def cancel!
      @executed = true
      @error = Canceled
    end

    def execute_or_skip
      return if @executed

      @pool.with_connection do |connection|
        return unless @mutex.try_lock
        begin
          return if @executed
          execute_query(connection, background: true)
        ensure
          @mutex.unlock
        end
      end
    end

    def result!
      execute_or_wait
      if @error
        raise @error
      else
        @result
      end
    end

    private
      def execute_or_wait
        return if @executed
        @mutex.synchronize do
          return if @executed
          execute_query(@pool.connection)
        end
      end

      def execute_query(connection, background: false)
        if @async_query_tracker.running?
          begin
            @result = exec_query(connection, *@args, **@kwargs, background: background)
          rescue => error
            @error = error
          ensure
            @executed = true
          end
        else
          @executed = true
          @error = Canceled
        end
      end

      def exec_query(connection, *args, **kwargs)
        connection.exec_query(*args, **kwargs)
      end

      class SelectAll < FutureResult
        private
          def exec_query(*, **)
            super
          rescue ::RangeError
            ActiveRecord::Result.new([], [])
          end
      end
  end
end
