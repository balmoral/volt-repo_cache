require 'set'
require 'volt/reactive/reactive_array'

# TODO: find a way around circular reference from collections to cache
module Volt
  module RepoCache
    class Collection < ModelArray
      include Volt::RepoCache::Util

      attr_reader :cache
      attr_reader :name
      attr_reader :model_class_name
      attr_reader :model_class
      attr_reader :repo_collection
      attr_reader :load_query
      attr_reader :cached_ids
      attr_reader :loaded # Promise
      attr_reader :marked_for_destruction
      attr_reader :associations
      attr_reader :read_only

      def initialize(cache: nil, name: nil, options: {})
        super(observer: self)
        @cache = cache
        @name = name
        @load_query = options[:query] || options[:where]
        @load_filter = options[:filter]
        @read_only = options[:read_only].nil? ? true : options[:read_only]
        @marked_for_destruction = {}
        @model_class_name = @name.to_s.singularize.camelize
        @model_class = Object.const_get(@model_class_name)
        @repo_collection = @cache.repo.send(name)
        init_associations(options)
        load
      end

      # hide circular reference to cache
      def inspect
        __tmp = @cache
        @cache = '{{hidden for inspect}}'
        result = super
        @cache = __tmp
        result
      end

      # Flushes each model in the array.
      # Returns a single Promise when
      # element promises are resolved.
      # TODO: error handling
      def flush!
        promises = []
        unless read_only
          # models are removed from @marked_from_destruction as
          # they are flushed, so we need a copy of them to enumerate
          @marked_for_destruction.values.dup.each do |e|
            # __debug 1, __FILE__, __LINE__, __method__, "@marked_for_destruction calling #{e.class}:#{e.id}.flush!"
            promises << e.flush!
            # __debug 1, __FILE__, __LINE__, __method__, "@marked_for_destruction called #{e.class}:#{e.id}.flush!"
          end
          each do |e|
            # __debug 1, __FILE__, __LINE__, __method__, "each calling #{e.class}:#{e.id}.flush!"
            promises << e.flush!
            # __debug 1, __FILE__, __LINE__, __method__, "each called #{e.class}:#{e.id}.flush!"
          end
        end
        Promise.when(*promises)
      end

      # Create a new model from given hash and append it to the collection.
      # Returns the new model
      def create(hash = {})
        append(hash.to_h)
      end

      # Appends a new model to the collection.
      # Model may be a hash which will be converted.
      # (See #induct for more.)
      # If the model belongs_to any other owners, the foreign id(s)
      # MUST be already set to ensure associational integrity
      # in the cache - it is easier to ask the owner for a new
      # instance (e.g. product.recipe.new_ingredient).
      # NB: Returns the newly appended model.
      def append(model, notify: true)
        model = induct(model, loaded_from_repo: false)
        __append__(model, notify: notify)
        model
      end

      # Returns self after appending the given model
      def <<(model)
        append(model)
        self
      end

      private

      def fail_if_read_only(what)
        if read_only
          raise RuntimeError, "cannot #{what} for read only cache collection"
        end
      end

      def uncache
        each {|e| e.send(:uncache)}
        associations.each_value {|e| e.send(:uncache)}
        @id_table.clear if @id_table
        @cache = @associations = @repo_collection = @id_table = nil
        __clear__
      end

      # Add the given model to marked_for_destruction list
      # and remove from collection. Should only be called
      # by RepoCache::Model#mark_for_destruction!.
      def mark_model_for_destruction(model)
        fail_if_read_only(__method__)
        # don't add if already in marked bucket
        if @marked_for_destruction[model.id]
          raise RuntimeError, "#{model} already in #{self.name} @marked_for_destruction"
        end
        @marked_for_destruction[model.id] = model
        __remove__(model, error_if_absent: true)
        @cached_ids.delete(model.id)
      end

      # Called by RepoCache::Model#__destroy__.
      # Remove model from marked_for_destruction bucket.
      # Don't worry if we can't find it.
      def destroyed(model)
        # __debug 1, __FILE__, __LINE__, __method__, "#{model.class}.id=#{model.id}"
        result = @marked_for_destruction.delete(model.id)
        # __debug 1, __FILE__, __LINE__, __method__, "@marked_for_destruction.delete(#{model.id}) => #{result}"
      end

      # Collection is being notified (probably by super/self)
      # that a model has been added or removed. Pass
      # this on to associations.
      def observe(action, model)
        # notify owner model(s) of appended model that it has been added
        notify_associations(action, model)
      end

      def notify_associations(action, model)
        associations.each_value do |assoc|
          notify_associates(assoc, action, model)
        end
      end

      # Notify models in the given association that
      # the given model has been deleted from or
      # appended to this collection. For example,
      # this collection may be for orders, and
      # association may be owner customer - thus
      # association will be belongs_to
      def notify_associates(assoc, action, model)
        if assoc.reciprocal
          local_id = model.send(assoc.local_id_field)
          if local_id # may not be set yet
            assoc.foreign_collection.each do |other|
              foreign_id = other.send(assoc.foreign_id_field)
              if local_id == foreign_id
                other.send(:refresh_association, assoc.reciprocal)
              end
            end
          end
        end
      end

      # 'Induct' a model into the cache via this collection.
      #
      # Called by #append.
      #
      # If the model is a hash then converts it to a full model.
      #
      # Patches the model with singleton methods and instance
      # variables required by cached models.
      #
      # Raises error if:
      # - the model has the wrong persistor for the cache
      # - the model class is not appropriate to this collection
      # - the model is not new and argument error_unless_new is true
      # - the model is already in the collection and error_if_present is true
      #
      # TODO: Also checks the model's associations:
      # - if it has no belongs_to associations then it is self sufficient
      #   (owned by no other) and can be added to the collection.
      # - if it should belong to (an)other model(s), then we require that
      #   the foreign id(s) are already set, otherwise we cannot ensure
      #   associational integrity in the cache.
      #
      # Returns the inducted model.
      def induct(model_or_hash, loaded_from_repo: false)
        model = if Hash === model_or_hash
          if loaded_from_repo
            raise TypeError, "cannot induct stored model from a hash #{model_or_hash}"
          end
          model_class.new(model_or_hash, options: {persistor: cache.persistor})
        else
          if !loaded_from_repo && model_or_hash.buffer?
            raise TypeError, "cannot induct new model_or_hash #{model_or_hash} with buffer"
          end
          model_or_hash
        end
        unless model.class == model_class
          raise ArgumentError, "#{model} must be a #{model_class_name}"
        end
        if model.cached?
          # __debug 1, ->{[__FILE__, __LINE__, __method__, "id=#{model.id} model.cached?=#{model.cached?}"]}
          raise TypeError, "model.id #{model.id} already in cache"
        end
        @cached_ids << model.id
        RepoCache::Model.induct_to_cache(model, self, loaded_from_repo)
        model
      end

      def cached?(model)
        @cached_ids.include?(model.id)
      end

      def load
        @cached_ids = Set.new  # append/delete will update
        q = @load_query ? repo_collection.where(@load_query) : repo_collection
        @loaded = q.all.map{|e|e}.then do |models|
          models.each do |_model|
            if @load_filter.nil? || @load_filter.call(_model)
              model = read_only ? _model : _model.buffer
              induct(model, loaded_from_repo: true)
              __append__(model, notify: false)
            end
          end
          self
        end
      end

      def init_associations(options)
        @associations = {}
        [:belongs_to, :has_one, :has_many].each do |type|
          arrify(options[type]).map(&:to_sym).each do |foreign_name|
            @associations[foreign_name] = Association.new(self, foreign_name, type)
          end
        end
      end

      def __debug(level, proc)
        file, line, method, msg = proc.call
         s = "#{file}[#{line}]:#{self.class.name}##{method}: #{msg}"
         if RUBY_PLATFORM == 'opal'
           Volt.logger.debug s
         else
           puts s
         end
       end

    end
  end
end
