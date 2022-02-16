# frozen_string_literal: true

require "mutex_m"
require "concurrent/map"
require "set"
require "active_support/core_ext/object/try"

module ActiveSupport
  module Notifications
    class InstrumentationSubscriberError < RuntimeError
      attr_reader :exceptions

      def initialize(exceptions)
        @exceptions = exceptions
        exception_class_names = exceptions.map { |e| e.class.name }
        super "Exception(s) occurred within instrumentation subscribers: #{exception_class_names.join(', ')}"
      end
    end

    module FanoutIteration
      def iterate_guarding_exceptions(listeners)
        exceptions = nil

        listeners.each do |s|
          yield s
        rescue Exception => e
          exceptions ||= []
          exceptions << e
        end

        if exceptions
          if exceptions.size == 1
            raise exceptions.first
          else
            raise InstrumentationSubscriberError.new(exceptions), cause: exceptions.first
          end
        end

        listeners
      end
    end


    # This is a default queue implementation that ships with Notifications.
    # It just pushes events to all registered log subscribers.
    #
    # This class is thread safe. All methods are reentrant.
    class Fanout
      include Mutex_m

      def initialize
        @string_subscribers = Hash.new { |h, k| h[k] = [] }
        @other_subscribers = []
        @listeners_for = Concurrent::Map.new
        super
      end

      def subscribe(pattern = nil, callable = nil, monotonic: false, &block)
        subscriber = Subscribers.new(pattern, callable || block, monotonic)
        synchronize do
          case pattern
          when String
            @string_subscribers[pattern] << subscriber
            @listeners_for.delete(pattern)
          when NilClass, Regexp
            @other_subscribers << subscriber
            @listeners_for.clear
          else
            raise ArgumentError,  "pattern must be specified as a String, Regexp or empty"
          end
        end
        subscriber
      end

      def unsubscribe(subscriber_or_name)
        synchronize do
          case subscriber_or_name
          when String
            @string_subscribers[subscriber_or_name].clear
            @listeners_for.delete(subscriber_or_name)
            @other_subscribers.each { |sub| sub.unsubscribe!(subscriber_or_name) }
          else
            pattern = subscriber_or_name.try(:pattern)
            if String === pattern
              @string_subscribers[pattern].delete(subscriber_or_name)
              @listeners_for.delete(pattern)
            else
              @other_subscribers.delete(subscriber_or_name)
              @listeners_for.clear
            end
          end
        end
      end

      class BaseGroup
        include FanoutIteration

        def initialize(listeners, name, id, payload)
          @listeners = listeners
          @name = name
          @id = id
          @payload = payload
        end

        def each(&block)
          iterate_guarding_exceptions(@listeners, &block)
        end
      end

      class BaseTimeGroup < BaseGroup
        def start
          @start_time = now
        end

        def finish
          @stop_time = now
          each do |listener|
            listener.publish(@name, @start_time, @stop_time, @id, @payload)
          end
        end
      end

      class MonotonicTimedGroup < BaseTimeGroup
        private
          def now
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
      end

      class TimedGroup < BaseTimeGroup
        private
          def now
            Time.now
          end
      end

      class EventedGroup < BaseGroup
        def start
          each do |s|
            s.start(@name, @id, @payload)
          end
        end

        def finish
          each do |s|
            s.finish(@name, @id, @payload)
          end
        end
      end

      class EventObjectGroup < BaseGroup
        def start
          @event = build_event(@name, @id, @payload)
          @event.start!
        end

        def finish
          @event.payload = @payload
          @event.finish!

          each do |s|
            s.publish_event(@event)
          end
        end

        private

          def build_event(name, id, payload)
            ActiveSupport::Notifications::Event.new name, nil, nil, id, payload
          end
      end

      class Handle
        def initialize(notifier, name, id, payload)
          @notifier = notifier
          @name = name
          @id = id
          @payload = payload

          @listeners = @notifier.listeners_for(name)

          @groups = @listeners.group_by(&:group_class)
          @groups = @groups.map do |group_klass, grouped_listeners|
            group_klass.new(grouped_listeners, @name, @id, @payload)
          end
        end

        def start
          @groups.each(&:start)
        end

        def finish
          @groups.each(&:finish)
        end
      end

      include FanoutIteration

      def get_handle(name, id, payload)
        Handle.new(self, name, id, payload)
      end

      def start(name, id, payload)
        raise "start called"
      end

      def finish(name, id, payload, listeners = listeners_for(name))
        raise "finish called"
      end

      def publish(name, *args)
        iterate_guarding_exceptions(listeners_for(name)) { |s| s.publish(name, *args) }
      end

      def publish_event(event)
        iterate_guarding_exceptions(listeners_for(event.name)) { |s| s.publish_event(event) }
      end

      def listeners_for(name)
        # this is correctly done double-checked locking (Concurrent::Map's lookups have volatile semantics)
        @listeners_for[name] || synchronize do
          # use synchronisation when accessing @subscribers
          @listeners_for[name] ||=
            @string_subscribers[name] + @other_subscribers.select { |s| s.subscribed_to?(name) }
        end
      end

      def listening?(name)
        listeners_for(name).any?
      end

      # This is a sync queue, so there is no waiting.
      def wait
      end

      module Subscribers # :nodoc:
        def self.new(pattern, listener, monotonic)
          subscriber_class = monotonic ? MonotonicTimed : Timed

          if listener.respond_to?(:start) && listener.respond_to?(:finish)
            subscriber_class = Evented
          else
            # Doing this to detect a single argument block or callable
            # like `proc { |x| }` vs `proc { |*x| }`, `proc { |**x| }`,
            # or `proc { |x, **y| }`
            procish = listener.respond_to?(:parameters) ? listener : listener.method(:call)

            if procish.arity == 1 && procish.parameters.length == 1
              subscriber_class = EventObject
            end
          end

          subscriber_class.new(pattern, listener)
        end

        class Matcher # :nodoc:
          attr_reader :pattern, :exclusions

          def self.wrap(pattern)
            if String === pattern
              pattern
            elsif pattern.nil?
              AllMessages.new
            else
              new(pattern)
            end
          end

          def initialize(pattern)
            @pattern = pattern
            @exclusions = Set.new
          end

          def unsubscribe!(name)
            exclusions << -name if pattern === name
          end

          def ===(name)
            pattern === name && !exclusions.include?(name)
          end

          class AllMessages
            def ===(name)
              true
            end

            def unsubscribe!(*)
              false
            end
          end
        end

        class Evented # :nodoc:
          attr_reader :pattern

          def initialize(pattern, delegate)
            @pattern = Matcher.wrap(pattern)
            @delegate = delegate
            @can_publish = delegate.respond_to?(:publish)
            @can_publish_event = delegate.respond_to?(:publish_event)
          end

          def group_class
            EventedGroup
          end

          def publish(name, *args)
            if @can_publish
              @delegate.publish name, *args
            end
          end

          def publish_event(event)
            if @can_publish_event
              @delegate.publish_event event
            else
              publish(event.name, event.time, event.end, event.transaction_id, event.payload)
            end
          end

          def start(name, id, payload)
            @delegate.start name, id, payload
          end

          def finish(name, id, payload)
            @delegate.finish name, id, payload
          end

          def subscribed_to?(name)
            pattern === name
          end

          def unsubscribe!(name)
            pattern.unsubscribe!(name)
          end
        end

        class Timed < Evented # :nodoc:
          def group_class
            TimedGroup
          end

          def publish(name, *args)
            @delegate.call name, *args
          end
        end

        class MonotonicTimed < Timed # :nodoc:
          def group_class
            MonotonicTimedGroup
          end
        end

        class EventObject < Evented
          def group_class
            EventObjectGroup
          end

          def publish_event(event)
            @delegate.call event
          end
        end
      end
    end
  end
end
