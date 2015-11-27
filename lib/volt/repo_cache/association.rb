module Volt
  module RepoCache
    class Association
      include Volt::RepoCache::Util

      attr_reader :local_name_singular, :local_name_plural
      attr_reader :local_collection
      attr_reader :foreign_name, :foreign_collection_name
      attr_reader :foreign_model_class_name, :foreign_model_class
      attr_reader :type, :foreign_id_field, :local_id_field

      def initialize(local_collection, foreign_name, type)
        _local_name = local_collection.name.to_s.sub(/^_/, '')
        @local_name_singular = _local_name.singularize.to_sym
        @local_name_plural = _local_name.pluralize.to_sym
        @local_collection = local_collection
        @foreign_name = foreign_name
        @type = type
        @foreign_model_class_name = @foreign_name.to_s.singularize.camelize
        @foreign_model_class = Object.const_get(@foreign_model_class_name)
        @foreign_collection_name = ('_' + @foreign_name.to_s.pluralize).to_sym
        @foreign_id_field = has_any? ? (@local_collection.model_class_name.underscore + '_id').to_sym : :id
        @local_id_field = belongs_to? ? (@foreign_name.to_s + '_id').to_sym : :id
      end

      # Hide circular references to local
      # and foreign collections for inspection.
      def inspect
        __local = @local_collection
        __foreign = @foreign_collection
        @local_collection = "{{#{@local_collection ? @local_collection.name : :nil}}"
        @foreign_collection = "{{#{@foreign_collection ? @foreign_collection.name : :nil}}"
        result = super
        @local_collection = __local
        @foreign_collection = __foreign
        result
      end

      def cache
        @local_collection.cache
      end

      # Must be lazy initialization since we
      # don't know order in which collections
      # will be loaded to cache.
      def foreign_collection
        @foreign_collection ||= cache.collections[@foreign_collection_name]
      end

      # Returns the reciprocal association
      # which may be nil if the foreign_collection
      # is not interested (has not specified)
      # the reciprocal association.
      # It may be, for example, that this association
      # is a belongs_to, but there is no reciprocal
      # has_one or has_many association in the 'owner'.
      # Must be lazy initialization since it depends on
      # foreign_collection being lazily initialized.
      def reciprocal
        unless @reciprocal
          # debug __method__, __LINE__, ""
          @reciprocal = foreign_collection.associations.values.detect do |a|
            # debug __method__, __LINE__, "#{a.foreign_collection.name} ?==? #{local_collection.name}"
            a.foreign_collection.name == local_collection.name
          end
          @reciprocal = :nil unless @reciprocal
          # debug __method__, __LINE__, "reciprocal of #{self.inspect} is #{@reciprocal.inspect}"
        end
        @reciprocal == :nil ? nil : @reciprocal
      end

      def reciprocated?
        !!reciprocal
      end

      def has_one?
        type == :has_one
      end

      def has_many?
        type == :has_many
      end

      def has_any?
        has_one? || has_many?
      end

      def belongs_to?
        type == :belongs_to
      end

      private

      def break_references
        @local_collection = @foreign_collection = @reciprocal = nil
      end

    end
  end
end