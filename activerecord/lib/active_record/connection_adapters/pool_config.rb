# frozen_string_literal: true

# :markup: markdown
module ActiveRecord
  module ConnectionAdapters
    class PoolConfig # :nodoc:
      include MonitorMixin

      attr_reader :db_config, :role, :shard, :connection_descriptor
      attr_writer :schema_reflection

      def schema_reflection
        @schema_reflection ||= SchemaReflection.new(db_config.lazy_schema_cache_path)
      end

      @next_pool_token = 0
      @pool_token_lock = Mutex.new

      class << self
        def next_pool_token
          if ActiveSupport::Ractors.main?
            @pool_token_lock.synchronize { @next_pool_token += 1 }
          else
            ActiveSupport::Ractors[:active_record_pool_token] = (ActiveSupport::Ractors[:active_record_pool_token] || 0) + 1
          end
        end

        def discard_pools!
          instances.each_key(&:discard_pool!)
        end

        def disconnect_all!
          instances.each_key { |c| c.disconnect!(automatic_reconnect: true) }
        end

        # Every Ractor tracks only the pool configs it created itself.
        def instances # :nodoc:
          ActiveSupport::Ractors.store_if_absent(:active_record_pool_config_instances) { ObjectSpace::WeakMap.new }
        end
      end

      def initialize(connection_class, db_config, role, shard)
        super()
        @server_version = nil
        self.connection_descriptor = connection_class
        @db_config = db_config
        @role = role
        @shard = shard
        @pool = nil
        @pool_token = nil
        self.class.instances[self] = self
      end

      def server_version(connection)
        @server_version || synchronize { @server_version ||= connection.get_database_version }
      end

      def connection_descriptor=(connection_descriptor)
        case connection_descriptor
        when ConnectionHandler::ConnectionDescriptor
          @connection_descriptor = connection_descriptor
        else
          @connection_descriptor = ConnectionHandler::ConnectionDescriptor.new(connection_descriptor.name, connection_descriptor.primary_class?)
        end
      end

      def disconnect!(automatic_reconnect: false)
        return unless @pool

        synchronize do
          return unless @pool

          @pool.automatic_reconnect = automatic_reconnect
          @pool.disconnect!
        end

        nil
      end

      def pool
        @pool || synchronize { @pool ||= ConnectionAdapters::ConnectionPool.new(self) }
      end

      def pool_token
        @pool_token || synchronize { @pool_token ||= self.class.next_pool_token }
      end

      def pool_spec
        spec = {
          db_config: db_config,
          connection_name: connection_descriptor.name.to_s.freeze,
          primary: connection_descriptor.primary_class?,
          role: role,
          shard: shard,
          pool_token: pool_token,
        }
        ActiveSupport::Ractors.make_shareable(spec, copy: true)
      end

      def discard_pool!
        return unless @pool

        synchronize do
          return unless @pool

          @pool.discard!
          @pool = nil
          @pool_token = nil
        end
      end
    end
  end
end

ActiveSupport::ForkTracker.after_fork { ActiveRecord::ConnectionAdapters::PoolConfig.discard_pools! }
