# frozen_string_literal: true

require "active_record/middleware/database_selector/resolver/session"

module ActiveRecord
  module Middleware
    class DatabaseSelector
      # The Resolver class is used by the DatabaseSelector middleware. It is
      # used to decide which database the request should use.
      #
      # The Resolver class should not be maniuplated directly. If your
      # application needs to change the behavior of the Resolver, it should
      # implement it's own Resolver using the same methods here and change
      # the definition of `read_from_primary?`.
      #
      # By default the Resolver class will send traffic to the replica if
      # it's been 5 seconds since the last write.
      class Resolver # :nodoc:
        SEND_TO_REPLICA_WAIT_TIME = 5.seconds

        def self.call(resolver)
          new(resolver)
        end

        def initialize(resolver)
          @resolver = resolver
          @instrumenter = ActiveSupport::Notifications.instrumenter
        end

        attr_reader :resolver, :instrumenter

        def read(&blk)
          if read_from_primary?
            read_from_primary(&blk)
          else
            read_from_replica(&blk)
          end
        end

        def write(&blk)
          write_to_primary(&blk)
        end

        private

          def read_from_primary(&blk)
            ActiveRecord::Base.connection.while_preventing_writes do
              ActiveRecord::Base.connected_to(role: :writing) do
                instrumenter.instrument("database_selector.active_record.read_from_primary") do
                  yield
                end
              end
            end
          end

          def read_from_replica(&blk)
            ActiveRecord::Base.connected_to(role: :reading) do
              instrumenter.instrument("database_selector.active_record.read_from_replica") do
                yield
              end
            end
          end

          def write_to_primary(&blk)
            ActiveRecord::Base.connected_to(role: :writing) do
              instrumenter.instrument("database_selector.active_record.wrote_to_primary") do
                resolver.update_last_write_timestamp
                yield
              end
            end
          end

          def read_from_primary?
            !time_since_last_write_ok?
          end

          def send_to_replica_wait_time
            SEND_TO_REPLICA_WAIT_TIME
          end

          def time_since_last_write_ok?
            Time.now - resolver.last_write_timestamp >= send_to_replica_wait_time
          end
      end
    end
  end
end
