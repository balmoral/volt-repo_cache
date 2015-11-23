require 'volt/reactive/reactive_array'

# TODO: find a way around circular reference from collections to cache
module Volt
  module RepoCache
    class Collection < ModelArray
      include Volt::RepoCache::Util

      attr_reader :cache
      attr_reader :owner
      attr_reader :name
      attr_reader :model_class_name
      attr_reader :model_class
      attr_reader :repo_collection
      attr_reader :load_query
      attr_reader :loaded_ids
      attr_reader :loaded # Promise
      attr_reader :marked_for_destruction
      attr_reader :associations

      def initialize(cache: nil, owner: nil, name: nil, options: {})
        # debug __method__, __LINE__, "name: #{name} options: #{options}"
        super(observer: self)
        @cache = cache
        @owner = owner
        @name = name
        @load_query = options[:query]
        @buffer = !!(options[:buffer] || options[:write])
        @marked_for_destruction = []
        @model_class_name = @name.to_s.singularize.camelize
        @model_class = Object.const_get(@model_class_name)
        @repo_collection = @cache.repo.send(name)
        init_associations(options)
        load
      end

      def owned?
        !!@owner
      end

      def buffer?
        @buffer
      end

      alias_method :write?, :buffer?

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
        # debug __method__, __LINE__
        promises = @marked_for_destruction.map {|e| e.flush! }
        # debug __method__, __LINE__, "after destruction flushes promises => #{promises}"
        promises = promises + map {|e| e.flush! }
        # debug __method__, __LINE__, "after upsert flushes: promises => #{promises}"
        result = Promise.when(*promises)
        # debug __method__, __LINE__, "after Promise.when: result => #{result}"
        result
      end

      # Appends a model to the collection.
      # Model may be a hash which will be converted.
      # Returns the collection (self).
      def append(model, error_if_present: true, error_unless_new: true, result: nil, notify: true)
        model = induct(model, error_unless_new: error_unless_new, error_if_present: error_if_present)
        result[0] = model if result
        super(model, notify: notify, caller: self)
        self
      end

      # Creates does append with default empty model.
      # Returns the created model.
      def create(model = {})
        result = []
        append(model, result: result)
        result[0]
      end

      def break_references(caller: nil)
        friends_only(__method__, caller)
        each {|e| e.break_references(caller: self)}
        associations.each_value {|e| e.break_references(caller: self)}
        @cache = @associations = @repo_collection = nil
        clear(caller: self)
        clear_observers(caller: self)
      end

      # Add the given model to marked_for_destruction and remove from collection.
      # This should only be called by RepoCache::Model#mark_for_destruction!.
      def mark_model_for_destruction(model: model, caller: nil)
        friends_only(__method__, caller)
        # don't add if already in marked bucket
        if @marked_for_destruction.detect {|e| e.id == model.id }
          raise RuntimeError, "#{model} already in #{self.name} @marked_for_destruction"
        end
        @marked_for_destruction << model
        remove(model, error_if_absent: true, caller: self)
      end

      # Not for general use.
      # Called by RepoCache::Model#destroy on successful destroy.
      # Remove model from marked_for_destruction bucket.
      # Don't worry if we can't find it.
      def destroyed(model, caller: nil)
        friends_only(__method__, caller)
        debug __method__, __LINE__, "getting index of #{model.class.name} #{model.id}"
        index = @marked_for_destruction.index {|e| e.id == model.id }
        debug __method__, __LINE__, "index = #{index}"
        @marked_for_destruction.delete_at(index) if index
      end

      # Collection is being notified (probably by super/self)
      # that a model has been added or removed. Pass
      # this on to associations.
      def observe(action, model, caller: nil)
        friends_only(__method__, caller)
        debug __method__, __LINE__, "action=#{action} model=#{model} caller=#{caller}"
        # notify owner model(s) of appended model that it has been added
        notify_associations(action, model)
      end

      private

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
        debug __method__, __LINE__, "action=#{action} model=#{model} assoc=#{assoc.inspect} reciprocate=#{assoc.reciprocal.inspect}"
        if assoc.reciprocal
          local_id = model.send(assoc.local_id_field)
          debug __method__, __LINE__, "local_id #{assoc.local_id_field}=#{local_id}"
          assoc.foreign_collection.each do |other|
            # debug __method__, __LINE__, "calling #{assoc.foreign_id_field} on #{other}"
            foreign_id = other.send(assoc.foreign_id_field)
            if local_id == foreign_id
              debug __method__, __LINE__, "foreign_id==local_id of #{other}, calling other.refresh_association(#{assoc.foreign_name})"
              other.refresh_association(assoc.reciprocal, caller: self)
            end
          end
        end
        debug __method__, __LINE__
      end

      # Called by #create, #append, #<<.
      # If the model is a hash then converts it to a new model.
      # Patches the model with singleton methods and instance variables
      # required by cached models.
      # Raises error if:
      # - the model has the wrong persistor for the cache
      # - the model class is not appropriate to this collection
      # - the model is not new and argument error_unless_new is true
      # - the model is already in collection and argument error_if_present is true
      #
      def induct(model, error_unless_new: true, error_if_present: true)
        model = if model.is_a?(Hash)
          model_class.new(model, options: {persistor: cache.persistor})
        else
          # unless model.persistor.class == cache.persistor.class
          #   raise RuntimeError, "model persistor is #{model.persistor} but should be #{cache.persistor}"
          # end
          unless model.class == model_class
            raise ArgumentError, "#{model} must be a #{model_class_name}"
          end
          if error_unless_new && !model.new?
            raise ArgumentError, "#{model} must be new"
          end
          if error_if_present && detect {|e| e.id == model.id}
            raise RuntimeError, "cannot add #{model} already in cached collection"
          end
          model
        end
        patch_for_cache(model)
      end

      # only to be called by cache
      def load
        @loaded_ids = []
        debug __method__, __LINE__, "@load_query=#{@load_query}"
        result = (@load_query ? repo_collection.where(@load_query) : repo_collection).all
        # debug __method__, __LINE__
        @loaded = result.collect{|e|e}.then do |models|
          # debug __method__, __LINE__, "load promise resolved to #{models.size} #{name}"
          models.each do |model|
            append(buffer? ? model.buffer : model, error_unless_new: false, notify: false)
            @loaded_ids << model.id
          end
          self
        end
        debug __method__, __LINE__, "@loaded => #{@loaded.class.name}:#{@loaded.value.class.name}"
      end

      def init_associations(options)
        @associations = {}
        [:belongs_to, :has_one, :has_many].each do |type|
          arrify(options[type]).map(&:to_sym).each do |foreign_name|
            @associations[foreign_name] = Association.new(self, foreign_name, type)
          end
        end
      end

      def patch_for_cache(model)
        unless model.respond_to?(:patched_for_cache?)
          RepoCache::Model.patch_for_cache(model, self)
        end
        model
      end

    end
  end
end
