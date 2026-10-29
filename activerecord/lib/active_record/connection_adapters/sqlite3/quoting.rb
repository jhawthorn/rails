# frozen_string_literal: true

# :markup: markdown
module ActiveRecord
  module ConnectionAdapters
    module SQLite3
      module Quoting # :nodoc:
        extend ActiveSupport::Concern

        module ClassMethods # :nodoc:
          def column_name_matcher
            /
              \A
              (
                (?:
                  # "table_name"."column_name" | function(one or no argument)
                  ((?:\w+\.|"\w+"\.)?(?:\w+|"\w+") | \w+\((?:|\g<2>)\))
                )
                (?:(?:\s+AS)?\s+(?:\w+|"\w+"))?
              )
              (?:\s*,\s*\g<1>)*
              \z
            /ix
          end

          def column_name_with_order_matcher
            /
              \A
              (
                (?:
                  # "table_name"."column_name" | function(one or no argument)
                  ((?:\w+\.|"\w+"\.)?(?:\w+|"\w+") | \w+\((?:|\g<2>)\))
                )
                (?:\s+COLLATE\s+(?:\w+|"\w+"))?
                (?:\s+ASC|\s+DESC)?
              )
              (?:\s*,\s*\g<1>)*
              \z
            /ix
          end

          # Quoted names are cached per Ractor, since a shared cache would have to be mutable.
          def quote_column_name(name)
            quoted_column_names[name] ||= %Q("#{name.to_s.gsub('"', '""')}").freeze
          end

          def quote_table_name(name)
            quoted_table_names[name] ||= %Q("#{name.to_s.gsub('"', '""').gsub(".", "\".\"")}").freeze
          end

          private
            def quoted_column_names
              ActiveSupport::Ractors.store_if_absent(:active_record_sqlite3_quoted_column_names) { Concurrent::Map.new }
            end

            def quoted_table_names
              ActiveSupport::Ractors.store_if_absent(:active_record_sqlite3_quoted_table_names) { Concurrent::Map.new }
            end
        end

        def quote(value) # :nodoc:
          case value
          when Numeric
            if value.finite?
              super
            else
              "'#{value}'"
            end
          else
            super
          end
        end

        def quote_string(s)
          ::SQLite3::Database.quote(s)
        end

        def quote_table_name_for_assignment(table, attr)
          quote_column_name(attr)
        end

        def quoted_time(value)
          value = value.change(year: 2000, month: 1, day: 1)
          quoted_date(value).sub(/\A\d\d\d\d-\d\d-\d\d /, "2000-01-01 ")
        end

        def quoted_binary(value)
          "x'#{value.hex}'"
        end

        def unquoted_true
          1
        end

        def unquoted_false
          0
        end

        def quote_default_expression(value, column) # :nodoc:
          if value.is_a?(Proc)
            value = value.call
            if value.match?(/\A\w+\(.*\)\z/)
              "(#{value})"
            else
              value
            end
          else
            super
          end
        end

        def type_cast(value) # :nodoc:
          case value
          when BigDecimal, Rational
            value.to_f
          when String
            if value.encoding == Encoding::ASCII_8BIT
              super(value.encode(Encoding::UTF_8))
            else
              super
            end
          else
            super
          end
        end
      end
    end
  end
end
