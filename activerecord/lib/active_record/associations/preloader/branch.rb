# frozen_string_literal: true

module ActiveRecord
  module Associations
    class Preloader
      class Branch #:nodoc:
        attr_reader :association, :children, :parent
        attr_reader :scope, :associate_by_default
        attr_writer :preloaded_records

        def initialize(association:, children:, parent:, associate_by_default:, scope:)
          @association = association
          @parent = parent
          @scope = scope
          @associate_by_default = associate_by_default

          @children = build_children(children)
          @loaders = nil
        end

        def referenced_classes
          (target_classes + children.flat_map(&:referenced_classes)).uniq
        end

        def referenced_tables
          (referenced_classes).map(&:table_name).uniq
        end

        def target_classes
          if parent.done?
            loaders.map(&:klass).uniq
          else
            parent.target_classes.flat_map do |klass|
              reflection = klass._reflect_on_association(@association)
              next [] unless reflection

              reflection.
                collect_join_chain.
                grep(Reflection::AssociationReflection).
                reject(&:polymorphic?).
                map(&:klass)
            end.uniq
          end
        end

        def target_tables
          target_classes.map(&:table_name).uniq
        end

        def root?
          parent.nil?
        end

        def source_records
          @parent.preloaded_records
        end

        def preloaded_records
          @preloaded_records ||= loaders.flat_map(&:preloaded_records)
        end

        def done?
          root? || (@loaders && @loaders.all?(&:run?))
        end

        def runnable_loaders
          loaders.flat_map(&:runnable_loaders).reject(&:run?)
        end

        def grouped_records
          h = {}
          source_records.each do |record|
            reflection = record.class._reflect_on_association(association)
            next if polymorphic_parent? && !reflection || !record.association(association).klass
            (h[reflection] ||= []) << record
          end
          h
        end

        def preloaders_for_reflection(reflection, reflection_records)
          reflection_records.group_by { |record| record.association(reflection.name).klass }.map do |rhs_klass, rs|
            preloader_for(reflection).new(rhs_klass, rs, reflection, scope, associate_by_default)
          end
        end

        def polymorphic_parent?
          return false if root?

          parent.polymorphic?
        end

        def polymorphic?
          return false if root?

          grouped_records.keys.any? do |reflection|
            reflection.options[:polymorphic]
          end
        end

        def loaders
          @loaders ||=
            grouped_records.flat_map do |reflection, reflection_records|
              preloaders_for_reflection(reflection, reflection_records)
            end
        end

        private
          def build_children(children)
            Array.wrap(children).flat_map { |association|
              Array(association).flat_map { |parent, child|
                Branch.new(
                  parent: self,
                  association: parent,
                  children: child,
                  associate_by_default: associate_by_default,
                  scope: scope
                )
              }
            }
          end

          # Returns a class containing the logic needed to load preload the data
          # and attach it to a relation. The class returned implements a `run` method
          # that accepts a preloader.
          def preloader_for(reflection)
            reflection.check_preloadable!

            if reflection.options[:through]
              ThroughAssociation
            else
              Association
            end
          end
      end
    end
  end
end
