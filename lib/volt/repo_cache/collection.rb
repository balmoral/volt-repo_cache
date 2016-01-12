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
      attr_reader :loaded_ids
      attr_reader :loaded # Promise
      attr_reader :marked_for_destruction
      attr_reader :associations
      attr_reader :read_only

      def initialize(cache: nil, name: nil, options: {})
        # debug __method__, __LINE__, "name: #{name} options: #{options}"
        super(observer: self)
        # debug __method__, __LINE__
        @cache = cache
        @name = name
        @load_query = options[:query] || options[:where]
        @read_only = options[:read_only].nil? ? true : options[:read_only]
        @marked_for_destruction = {}
        @model_class_name = @name.to_s.singularize.camelize
        @model_class = Object.const_get(@model_class_name)
        @repo_collection = @cache.repo.send(name)
        init_associations(options)
        load
        # debug __method__, __LINE__
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
            promises << e.flush!
          end
          each do |e|
            promises << e.flush!
          end
        end
        Promise.when(*promises)
      end

      # Create a new model from given hash and append it to the collection.
      # Returns the new model
      def create(hash = {})
        append(hash.to_h)
      end

      # Appends a model to the collection.
      # Model may be a hash which will be converted.
      # (See #induct for more.)
      # If the model belongs_to any other owners, the foreign id(s)
      # MUST be already set to ensure associational integrity
      # in the cache - it is easier to ask the owner for a new
      # instance (e.g. product.recipe.new_ingredient).
      # NB: Returns the newly appended model.
      def append(model, error_if_present: true, error_unless_new: true,  notify: true)
        model = induct(model, error_unless_new: error_unless_new, error_if_present: error_if_present)
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
      end

      # Called by RepoCache::Model#__destroy__.
      # Remove model from marked_for_destruction bucket.
      # Don't worry if we can't find it.
      def destroyed(model)
        @loaded_ids.delete(model.id)
        @marked_for_destruction.delete(model.id)
      end

      # Collection is being notified (probably by super/self)
      # that a model has been added or removed. Pass
      # this on to associations.
      def observe(action, model)
        debug __method__, __LINE__, "action=#{action} model=#{model} associations=#{associations}"
        # notify owner model(s) of appended model that it has been added
        notify_associations(action, model)
      end

      def notify_associations(action, model)
        debug __method__, __LINE__, "action=#{action} model=#{model} associations=#{associations}"
        associations.each_value do |assoc|
          debug __method__, __LINE__, "calling notify_associates(#{assoc}, #{action}, #{model})"
          notify_associates(assoc, action, model)
          debug __method__, __LINE__, "called notify_associates(#{assoc}, #{action}, #{model})"
        end
      end

      # Notify models in the given association that
      # the given model has been deleted from or
      # appended to this collection. For example,
      # this collection may be for orders, and
      # association may be owner customer - thus
      # association will be belongs_to
      def notify_associates(assoc, action, model)
        # debug __method__, __LINE__, "action=#{action} model=#{model} assoc=#{assoc} reciprocate=#{assoc.reciprocal}"
        if assoc.reciprocal
          local_id = model.send(assoc.local_id_field)
          # debug __method__, __LINE__, "local_id #{assoc.local_id_field}=#{local_id}"
          if local_id # may not be set yet
            assoc.foreign_collection.each do |other|
              # debug __method__, __LINE__, "calling #{assoc.foreign_id_field} on #{other}"
              foreign_id = other.send(assoc.foreign_id_field)
              if local_id == foreign_id
                # debug __method__, __LINE__, "foreign_id==local_id of #{other}, calling other.refresh_association(#{assoc.foreign_name})"
                other.send(:refresh_association, assoc.reciprocal)
              end
            end
          end
        end
        # debug __method__, __LINE__
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
      def induct(model_or_hash, error_unless_new: true, error_if_present: true)
        created_in_cache = false
        if model_or_hash.is_a?(Hash)
          created_in_cache = true
          model = model_class.new(model_or_hash, options: {persistor: cache.persistor})
        else
          model = model_or_hash
          # unless model.persistor.class == cache.persistor.class
          #   raise RuntimeError, "model persistor is #{model.persistor} but should be #{cache.persistor}"
          # end
          unless model.class == model_class
            raise ArgumentError, "#{model} must be a #{model_class_name}"
          end
          if error_unless_new && (!model.created_in_cache? || model.new?)
            raise ArgumentError, "#{model} must be new (not stored) or have been created in cache"
          end
          if error_if_present && @loaded_ids.include?(model.id)
            raise RuntimeError, "cannot add #{model} already in cached collection"
          end
        end
        @loaded_ids << model.id
        patch_for_cache(model, created_in_cache)
        model
      end

      def load
        # debug __method__, __LINE__
        @loaded_ids = Set.new  # append/delete will update
        q = @load_query ? repo_collection.where(@load_query) : repo_collection
        # t1 = Time.now
        @loaded = q.all.collect{|e|e}.then do |models|
          # t2 = Time.now
          # debug __method__, __LINE__, "#{name} read_only=#{read_only} query promise resolved to #{models.size} models in #{t2-t1} seconds"
          models.each do |model|
            append(read_only ? model : model.buffer, error_unless_new: false, notify: false)
          end
          # t3 = Time.now
          # debug __method__, __LINE__, "#{name} loaded ids for #{models.size} #{name} in #{t3-t2} seconds"
          self
        end
        # debug __method__, __LINE__, "@loaded => #{@loaded.class.name}:#{@loaded.value.class.name}"
      end

      def init_associations(options)
        # debug __method__, __LINE__, "options = #{options}"
        @associations = {}
        [:belongs_to, :has_one, :has_many].each do |type|
          arrify(options[type]).map(&:to_sym).each do |foreign_name|
            @associations[foreign_name] = Association.new(self, foreign_name, type)
            # debug __method__, __LINE__, "@associations[#{foreign_name}] = #{@associations[foreign_name].inspect}"
          end
        end
      end

      def patch_for_cache(model, created_in_cache)
        unless model.respond_to?(:patched_for_cache?)
          RepoCache::Model.patch_for_cache(model, self, created_in_cache)
        end
        model
      end

    end
  end
end
