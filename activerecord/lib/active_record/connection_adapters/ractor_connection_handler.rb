# frozen_string_literal: true

# :markup: markdown

module ActiveRecord
  module ConnectionAdapters
    # Worker-Ractor stand-in for ConnectionHandler
    class RactorConnectionHandler # :nodoc:
      autoload :Proxy, "active_record/connection_adapters/ractor_connection_handler/proxy"
      autoload :ProxyConnectionPool, "active_record/connection_adapters/ractor_connection_handler/proxy_connection_pool"
      autoload :AbstractProxyAdapter, "active_record/connection_adapters/ractor_connection_handler/abstract_proxy_adapter"
      autoload :MysqlProxyAdapter, "active_record/connection_adapters/ractor_connection_handler/mysql_proxy_adapter"
      autoload :PostgreSQLProxyAdapter, "active_record/connection_adapters/ractor_connection_handler/postgresql_proxy_adapter"
      autoload :SQLite3ProxyAdapter, "active_record/connection_adapters/ractor_connection_handler/sqlite3_proxy_adapter"

      include Proxy

      def self.instance
        ActiveSupport::Ractors[:active_record_ractor_connection_handler_instance] ||= new
      end

      # Set to false to proxy every connection to the main Ractor, even when the
      # driver could be used from the worker Ractor itself.
      @local_connections = true

      class << self
        attr_accessor :local_connections # :nodoc:
      end

      # Whether connections for this config can be opened by the Ractor that
      # uses them, rather than proxied to the main Ractor. An in-memory database
      # only exists inside the connection that created it, so it must be shared.
      def self.local_connections?(db_config) # :nodoc:
        local_connections && !ActiveSupport::Ractors.main? &&
          db_config.adapter == "sqlite3" &&
          defined?(::SQLite3) && ::SQLite3.respond_to?(:ractor_safe?) && ::SQLite3.ractor_safe? &&
          db_config.database.to_s != ":memory:" && !db_config.database.to_s.include?("mode=memory")
      end

      # Pool for a spec published by the main Ractor. Where the adapter's driver
      # is Ractor safe this Ractor owns a real ConnectionPool of its own; otherwise
      # it gets a stand-in forwarding to the main Ractor's pool.
      def pool_for_spec(spec)
        return ProxyConnectionPool.for_spec(spec) unless self.class.local_connections?(spec.fetch(:db_config))

        pools = ActiveSupport::Ractors.store_if_absent(:active_record_ractor_local_pools) { Concurrent::Map.new }
        key = [spec.fetch(:connection_name), spec.fetch(:role), spec.fetch(:shard), spec.fetch(:pool_token)]
        pools.compute_if_absent(key) do
          descriptor = ConnectionHandler::ConnectionDescriptor.new(spec.fetch(:connection_name), spec.fetch(:primary))
          PoolConfig.new(descriptor, spec.fetch(:db_config), spec.fetch(:role), spec.fetch(:shard)).pool
        end
      end

      # Blocks handed to main_operation may only capture single-assignment locals
      def connection_pool_list(role = nil)
        connection_role = role
        pool_specs = main_operation do
          specs = main_connection_handler.connection_pool_list(connection_role).map { |pool| pool.pool_config.pool_spec }
          ActiveSupport::Ractors.make_shareable(specs, copy: false)
        end
        pool_specs.map { |pool_spec| pool_for_spec(pool_spec) }
      end
      alias :connection_pools :connection_pool_list

      def connection_pool_names
        connection_pool_list.map { |pool| pool.connection_descriptor.name }.uniq
      end

      def each_connection_pool(role = nil, &block)
        return enum_for(__method__, role) unless block_given?

        connection_pool_list(role).each(&block)
      end

      def retrieve_connection(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard)
        retrieve_connection_pool(connection_name, role: role, shard: shard, strict: true).lease_connection
      end

      def retrieve_connection_pool(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard, strict: false)
        shareable_connection_name = ActiveSupport::Ractors.make_shareable(connection_name.to_s)
        connection_role = role
        connection_shard = shard
        strict_lookup = strict

        # A Ractor's own pools are reused without asking the main Ractor, which is only
        # consulted the first time a name, role and shard are seen. Pools established
        # on the main Ractor afterwards are not noticed until retrieved_pools is cleared.
        cache_key = [shareable_connection_name, connection_role, connection_shard]
        cached_pool = retrieved_pools[cache_key]
        return cached_pool if cached_pool

        pool_spec = main_operation do
          pool = main_connection_handler.retrieve_connection_pool(
            shareable_connection_name,
            role: connection_role,
            shard: connection_shard,
            strict: strict_lookup,
          )
          pool && pool.pool_config.pool_spec
        end
        retrieved = pool_spec && pool_for_spec(pool_spec)
        retrieved_pools[cache_key] = retrieved if retrieved.is_a?(ConnectionPool)
        retrieved
      end

      def connected?(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard)
        pool = retrieve_connection_pool(connection_name, role: role, shard: shard)
        pool && pool.connected?
      end

      def active_connections?(role = nil)
        role = nil if role == :all
        ConnectionPool.each_used_pool do |pool|
          return true if manages?(pool, role) && pool.active_connection?
        end
        false
      end

      def clear_active_connections!(role = nil)
        role = nil if role == :all
        ConnectionPool.each_used_pool do |pool|
          next unless manages?(pool, role)

          pool.release_connection
          pool.reset_query_cache!
        end
      end

      def clear_reloadable_connections!(role = nil)
        clear_active_connections!(role)
      end

      def clear_all_connections!(role = nil)
        each_connection_pool(role).each(&:disconnect!)
      end

      def flush_idle_connections!(role = nil)
        each_connection_pool(role).each(&:flush!)
      end

      def establish_connection(config, owner_name: Base, role: Base.current_role, shard: Base.current_shard, clobber: false)
        connection_owner_name = owner_name
        db_config = ActiveSupport::Ractors.make_shareable(config)
        connection_role = role
        connection_shard = shard
        clobber_existing = clobber

        retrieved_pools.clear

        pool_spec = main_operation do
          pool = main_connection_handler.establish_connection(
            db_config.dup,
            owner_name: connection_owner_name,
            role: connection_role,
            shard: connection_shard,
            clobber: clobber_existing,
          )
          pool.pool_config.pool_spec
        end

        pool_for_spec(pool_spec)
      end

      def remove_connection_pool(connection_name, role: ActiveRecord::Base.current_role, shard: ActiveRecord::Base.current_shard)
        retrieved_pools.clear
        shareable_connection_name = ActiveSupport::Ractors.make_shareable(connection_name.to_s)
        connection_role = role
        connection_shard = shard

        main_operation do
          main_connection_handler.remove_connection_pool(
            shareable_connection_name, role: connection_role, shard: connection_shard
          )
        end
      end

      def main_ractor_handler
        Proxy.main_connection_handler
      end

      private
        def retrieved_pools
          ActiveSupport::Ractors.store_if_absent(:active_record_ractor_retrieved_pools) { Concurrent::Map.new }
        end

        def manages?(pool, role)
          (pool.is_a?(ProxyConnectionPool) || pool.is_a?(ConnectionPool)) && (role.nil? || pool.role == role)
        end
    end
  end
end
