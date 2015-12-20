# used by RepoCache::Collection
# TODO: relies excessively on singleton methods
# - look at refactor which moves the
# methods to the module and provides
# the instance as argument.

module Volt
  module RepoCache
    module Model
      extend Volt::RepoCache::Util

      def self.patch_for_cache(model, collection)
        model.instance_variable_set(:@collection, collection)
        model.instance_variable_set(:@associations, {})
        model.instance_variable_set(:@marked_for_destruction, false)

        # TODO: if model is not buffered, then trap all
        # field set value methods and raise exception -
        # unless buffered the model is read only.

        # create bunch of instance singleton methods
        # for association management
        collection.associations.each_value do |assoc|
          foreign_name = assoc.foreign_name

          if assoc.belongs_to?
            # ensure id's of owners are set in the model
            unless model.send(assoc.local_id_field)
              raise RuntimeError, "#{assoc.local_id_field} must be set for #{model}"
            end

            # trapper: `model.owner_id=` for belongs_to associations.
            # e.g. recipe.product_id = product.id
            # - validates the local id is in the foreign cached collection
            # - notifies associated models as required
            # NB this overrides a model's foreign_id set methods
            model.define_singleton_method(setter(assoc.local_id_field)) do |new_foreign_id|
              trapped_set_owner_id(assoc, new_foreign_id)
            end
          end

          # reader: `model.something` method for belongs_to, has_one and has_many
          # e.g. product.recipe
          model.define_singleton_method(foreign_name) do
            get_association(assoc)
          end

          unless collection.read_only
            # writer: `model.something=` methods for belongs_to, has_one and has_many
            # e.g. product.recipe = Recipe.new
            # e.g. product.recipe.ingredients = [...]
            model.define_singleton_method(setter(foreign_name)) do |model_or_array|
              set_association(assoc, model_or_array)
            end

            # creator: `model.new_something` method for has_one and has_many
            # will set foreign id in the newly created  model.
            # e.g. recipe = product.new_recipe
            # e.g. ingredient = product.recipe.new_ingredient({product: flour})
            if assoc.has_any?
              model.define_singleton_method(creator(foreign_name), Proc.new { |args|
                new_association(assoc, args)
              })
            end

            # add and remove has_many association values
            if assoc.has_many?
              # add to has_many: `model.add_something`
              # e.g. product.recipe.add_ingredient(Ingredient.new)
              model.define_singleton_method(adder(foreign_name)) do |other|
                add_to_many(assoc, other)
              end
              # remove from has_many: `model.remove_something`
              # e.g. product.recipe.remove_ingredient(ingredient)
              model.define_singleton_method(remover(foreign_name)) do |other|
                remove_from_many(assoc, other)
              end
            end
          end

        end

        # Use respond_to?(:patched_for_cache?) to determine
        # whether a model's behaviour has been patched here
        # to operate in the cache (if you called the method
        # directly on a non-patched model you would raise
        # method_missing).
        def model.patched_for_cache?
          true
        end

        # Returns true if the model has been marked
        # for destruction on flush. Otherwise false.
        def model.marked_for_destruction?
          @marked_for_destruction
        end

        # Returns the cached collected the model belongs to.
        def model.collection
          @collection
        end

        # Returns the cache the model belongs to.
        def model.cache
          @collection.cache
        end

        # Hide circular reference to collection
        # when doing inspection.
        def model.inspect
          __tmp = @collection
          @collection = "{{#{@collection.name}}}"
          result = super
          @collection = __tmp
          result
        end

        unless collection.read_only
          # Locks the model in the underlying repo.
          # Not yet implemented.
          def model.lock!
            raise RuntimeError, 'lock support coming'
          end

          # Marks the model and all its 'has_' associations
          # for destruction when model, collection or cache
          # is flushed.
          def model.mark_for_destruction!
            # prevent collection going in circles on this
            # (we don't know whether initial request was to
            # self or to collection which holds self)
            unless @marked_for_destruction
              debug __method__, __LINE__, "marking #{self} for destruction"
              @marked_for_destruction = true
              @collection.send(:mark_model_for_destruction, self)
              mark_associations_for_destruction
            end
          end

          # Flushes changes in the model to the repo.
          #
          # - if new will insert (append) the model to the repo
          #
          # - if dirty will update (save) the buffer to the repo
          #
          # - if new or dirty will flush all has_ associations
          #
          # - if marked_for_destruction will destroy the model
          #   and all its has_one and has_many associations
          #
          # Returns a promise with model as value..
          #
          # WARNING
          # - flush! is not (yet) an atomic transaction
          # - any part of it may fail without unwinding the whole
          def model.flush!
            fail_if_read_only(__method__)
            if @marked_for_destruction
              # debug __method__, __LINE__, "marked for destruction so call destroy"
              __destroy__
            else
              if new? || dirty?
                # debug __method__, __LINE__
                if new?
                  # debug __method__, __LINE__
                  @collection.repo_collection << self
                else
                  # debug __method__, __LINE__
                  __save__
                end
              else
                # neither new nor dirty but
                # stay in the promise chain
                Promise.value(self)
              end
            end.then do
              self
            end
          end

          # Returns true if proxy is buffered and the
          # buffer has changed from original model.
          # If proxy is new model return true.
          # Assumes fields defined for model.
          # Does not check associations.
          def model.dirty?
            # fields_data is a core Volt class method
            self.class.fields_data.keys.each do |field|
              return true if changed?(field)
            end
            new?
          end

          def destroy(caller: nil)
            fail_if_read_only(__method__)
            unless caller.object_id == self.object_id
              raise RuntimeError, "cached model should be marked for destruction - cannot destroy directly"
            end
            super()
          end

          def save!(caller: nil)
            fail_if_read_only(__method__)
            unless caller.object_id == self.object_id
              raise RuntimeError, "cached model should be flushed - cannot save directly"
            end
            super()
          end
        end

        # #######################################
        # FOLLOWING ARE INTENDED FOR INTERNAL USE
        # Error will be raised unless caller's
        # class namespace is Volt::RepoCache.
        # #######################################

        def model.fail_if_read_only(what)
          if @collection.read_only
            raise RuntimeError, "cannot #{what} for read only cache collection/model"
          end
        end
        model.singleton_class.send(:private, :fail_if_read_only)

        # private
        def model.break_references
          @associations.clear if @associations
          @collection = @associations = nil
        end
        model.singleton_class.send(:private, :break_references)

        # private
        # Used by cached collections to notify
        # reciprocal associated model(s) that
        # they need to refresh association queries.
        #
        # Raise error unless caller's class namespace is Volt::RepoCache.
        def model.refresh_association(association)
          # debug __method__, __LINE__, "association=#{association.foreign_name}"
          # refresh the association query
          result = get_association(association, refresh: true)
          # debug __method__, __LINE__, "#{self} association=#{association} result=#{result}"
        end
        model.singleton_class.send(:private, :refresh_association)

        # Returns a promise
        def model.__save__
          save!(caller: self)
        end
        model.singleton_class.send(:private, :__save__)

        # private
        # Destroys the underlying model in the underlying repository.
        # NB in Volt 0.9.6 there's a problem with destroy if
        # MESSAGE_BUS is on and there's another connection
        # (e.g. console) running.
        # Returns a promise with destroyed model proxy as value.
        def model.__destroy__
          debug __method__, __LINE__
          fail_if_read_only(what)
          if new?
            Promise.error("cannot delete new model proxy for #{@model.class.name} #{@model.id}")
          else
            debug __method__, __LINE__
            promise = destroy(caller: self)
            debug __method__, __LINE__
            promise.then do |m|
              debug __method__, __LINE__, "destroy promise resolved to #{m}"
              @collection.destroyed(self)
              break_references
              self
            end.fail do |errors|
              debug __method__, __LINE__, "destroy failed => #{errors}"
              errors
            end
          end
        end
        model.singleton_class.send(:private, :__destroy__)

        # private
        # Get the model for the given association
        # (belongs_to, has_one or has_many).
        #
        # If refresh is true then re-query from
        # cached foreign collection. Keep result
        # of association in instance variable
        # for later fast access.
        #
        # Relies on cached collections notifying
        # associated models when to refresh.
        def model.get_association(assoc, refresh: false)
          # debug __method__, __LINE__, "#{self.class.name}:#{id} assoc=#{assoc.foreign_name} refresh: #{refresh}"
          foreign_name = assoc.foreign_name
          @associations[foreign_name] = nil if refresh
          prior = @associations[foreign_name]
          local_id = self.send(assoc.local_id_field)
          foreign_id_field = assoc.foreign_id_field
          # debug __method__, __LINE__, "foreign_id_field=#{foreign_id_field}"
          result = if prior && match?(prior, foreign_id_field, local_id)
            prior
          else
            q = {foreign_id_field => local_id}
            r = assoc.foreign_collection.query(q) || []
            @associations[foreign_name] = assoc.has_many? ? ModelArray.new(contents: r) : r.first
          end
          result
        end
        model.singleton_class.send(:private, :get_association)

        # private
        # For the given has_one or has_many association,
        # create a new instance of the association's
        # foreign model class with its foreign_id set
        # appropriately.
        #
        # WARNING: If the association is has_one,
        # the prior foreign model will be marked for
        # destruction.
        #
        # If the association is has_many, the new
        # foreign model will be added to the many.
        #
        # has_one example: if model is a product and
        # association is has_one :recipe, then
        # `product.new_recipe` will create a new Recipe
        # with `recipe.product_id` set to `product.id`,
        # and `product.recipe` new return the new recipe.
        # NB this will mark any existing recipe for
        # destruction.
        #
        # has_many example: if model is a recipe and
        # association is has_many :ingredients, then
        # `recipe.new_ingredient` will create a new
        # Ingredient with `ingredient.recipe_id` set
        # to `recipe.id`, and `recipe.ingredients` will
        # now include the new ingredient.
        def model.new_association(assoc, args)
          fail_if_read_only(what)
          other = assoc.foreign_model_class.new(args.merge({
            assoc.foreign_id_field => self.send(assoc.local_id_field)
          }))
          if assoc.has_one?
            set_association(assoc, other)
          else
            add_to_many(assoc, other)
          end
          other
        end
        model.singleton_class.send(:private, :new_association)


        # private
        # Set the associated value for the give belongs_to,
        # has_one or has_many association,
        #
        # e.g. has_one: `product.recipe = Recipe.new`
        # e.g. has_many: `product.recipe.ingredients = [...]`
        # e.g. belongs_to: `ingredient.product = cache._products.where(code: 'SDO')`
        #
        # An exception will be raised if given value is
        # not appropriate to the association.
        #
        # WARNING: if the association is has_one or
        # has_many then any prior associated values
        # will be marked for destruction.
        #
        # NB we don't immediately update local @associations,
        # but wait to be notified by associated collections
        # of changes we make to them. This ensures that
        # if changes are made to those collections that
        # have not gone through this method, that everything
        # is still in sync.
        def model.set_association(assoc, value)
          if assoc.belongs_to?
            prior = send(assoc.local_id_field)
            if prior
              raise RuntimeError, "#{self} belongs to another #{assoc.foreign_model_class_name}"
            end
            validate_foreign_class(assoc, value)
            # Set the local id to the foreign id
            send(Util.setter(assoc.local_id_field), value.id)
          else
            prior = get_association(assoc)
            if assoc.has_one?
              set_one(assoc, value, prior)
            elsif assoc.has_many?
              set_many(assoc, value, prior)
            else
              raise RuntimeError, "set_association cannot handle #{assoc.inspect}"
            end
          end
        end
        model.singleton_class.send(:private, :set_association)

        # private
        def model.set_one(assoc, other, prior)
          fail_if_read_only(what)
          validate_foreign_class(assoc, other)
          # the prior is no longer required
          prior.mark_for_destruction! if prior
          # Set the foreign_id of the new_value to this model's id.
          set_foreign_id(assoc, other)
          # Add to cache if not already there, which will raise an exception
          # if the new_Value is not new or is not the appropriate class.
          assoc.foreign_collection.append(other, error_if_present: false)
          other
        end
        model.singleton_class.send(:private, :set_one)

        # private
        def model.set_many(assoc, new_values, prior_values)
          fail_if_read_only(what)
          unless new_values.respond_to?(:to_a)
            raise RuntimeError, "value for setting has_many #{assoc.foreign_name} must respond to :to_a"
          end
          new_values = new_values.to_a
          # set foreign_id of all new values to this model's id
          new_values.each do |model|
            set_foreign_id(assoc, model)
          end
          if prior_values
            # destroy any prior values not in new values
            prior_values.each do |p|
              unless new_values.detect {|n| p.id == n.id}
                p.mark_for_destruction!
              end
            end
          end
          # add any new values - #add_to_many
          # handle case where new value is in
          # prior values
          new_values.each do |new_value|
            add_to_many(new_value)
          end
        end
        model.singleton_class.send(:private, :set_many)

        # private
        # Add model to has_many association if not already there.
        # Will raise an exception if the new association
        # is not new or is not the appropriate class.
        def model.add_to_many(assoc, other)
          fail_if_read_only(what)
          set_foreign_id(assoc, other)
          assoc.foreign_collection.append(other, error_if_present: false)
        end
        model.singleton_class.send(:private, :add_to_many)

        # private
        # Mark the given associated model for destruction if
        # it's owner id equals this model's id. Return the
        # the marked model. Raises exception if the given
        # associated model does not belongs to this model.
        def model.remove_from_many(assoc, other)
          validate_ownership(assoc, other)
          other.mark_for_destruction!
        end
        model.singleton_class.send(:private, :remove_from_many)

        # private
        # Sets the appropriate foreign_id of the other model
        # to this model's id. Raises an exception if the
        # foreign_id is already set and not this model's
        # (i.e. if the associate belongs to another model).
        def model.set_foreign_id(assoc, other)
          fail_if_read_only(what)
          validate_ownership(assoc, other, require_foreign_id: false) do |prior_foreign_id|
            # after validation we can be sure prior_foreign_id == self.id
            # debug __method__, __LINE__
            unless prior_foreign_id
              other.send(Util.setter(assoc.foreign_id_field), id)
            end
            # debug __method__, __LINE__
          end
        end
        model.singleton_class.send(:private, :set_foreign_id)

        # private
        # An owner id in the model has been set to a new value
        # for the given belongs_to association. Find the value in the
        # association's foreign_collection for the new owner
        # id. If not found raise an exception. Then use
        # set_association method to do the rest, including notification
        # of owner/reciprocal association.
        def model.trapped_set_owner_id(assoc, new_owner_id)
          fail_if_read_only(what)
          new_value = assoc.foreign_collection.detect do |e|
            e.id == new_owner_id
          end
          unless new_value
            raise RuntimeError, "no model found in foreign collection #{assoc.foreign_collection_name} for #{assoc.local_id} { #{new_owner_id}"
          end
          set_association(assoc, new_value)
        end
        model.singleton_class.send(:private, :trapped_set_owner_id)

        # private
        # Validate that the appropriate foreign_id in the associate
        # matches this model's id. If the associate's foreign_id is
        # nil (not yet set) raise an error if require_foreign_id is
        # true. If the associate's foreign_id is set, raise an error
        # if it does not match this model's id. Otherwise return true
        # if the foreign id is not nil. Yield to given block if provided.
        def model.validate_ownership(assoc, other, require_foreign_id: true, &block)
          # debug __method__, __LINE__
          foreign_id = other.send(assoc.foreign_id_field)
          # debug __method__, __LINE__
          if (foreign_id && foreign_id != self.id) || (require_foreign_id && foreign_id.nil?)
            raise RuntimeError, "#{other} should belong to #{self} or no-one else"
          end
          yield(foreign_id) if block
        end
        model.singleton_class.send(:private, :validate_ownership)

        # private
        def model.validate_foreign_class(assoc, other)
          unless other.is_a?(assoc.foreign_model_class)
            raise RuntimeError, "#{self.class.name}##{assoc.foreign_name}= must be a #{assoc.foreign_model_class_name}"
          end
        end
        model.singleton_class.send(:private, :validate_foreign_class)

        # private
        def model.validate_patched_for_cache(model_or_array)
          Util.arrify(model_or_array).each do |other|
            unless other.respond_to?(:patched_for_cache?)
              raise RuntimeError, "#{other} must be loaded into or created via cache"
            end
          end
        end
        model.singleton_class.send(:private, :validate_patched_for_cache)

        # private
        # Returns whether the id in the foreign_id_field
        # matches the given local id.  If the target is
        # an array then we check whether it's first element
        # matches (or if it's empty assume true?).
        def model.match?(other, foreign_id_field, local_id)
          target = other.respond_to?(:to_a) ? other.first : other
          target ? target.send(foreign_id_field) == local_id : true
        end
        model.singleton_class.send(:private, :match?)

        # private
        # Calls flush on each has_one and has_many association.
        # Returns a single promise which collates all promises
        # from flushing associates.
        def model.flush_associations
          promises = []
          @collection.associations.values.each do |assoc|
            if assoc.has_any?
              # debug __method__, __LINE__, "association => '#{association}'"
              model_or_array = send(assoc.foreign_name)
              # debug __method__, __LINE__, "model_or_array => '#{model_or_array}'"
              Util.arrify(model_or_array).each do |model|
                promises << model.flush!
              end
              # debug __method__, __LINE__
            end
          end
          Promise.when(*promises)
        end
        model.singleton_class.send(:private, :flush_associations)

        # private
        # Marks all has_one or has_many models for destruction
        def model.mark_associations_for_destruction
          fail_if_read_only(what)
          @collection.associations.values.each do |assoc|
            if assoc.has_any?
              # debug __method__, __LINE__, "association => '#{association}'"
              model_or_array = send(assoc.foreign_name)
              if model_or_array
                # debug __method__, __LINE__, "model_or_array => '#{model_or_array}'"
                Util.arrify(model_or_array).each do |model|
                  model.mark_for_destruction!
                end
                # debug __method__, __LINE__
              end
            end
          end
        end
        model.singleton_class.send(:private, :mark_associations_for_destruction)

        def model.debug(method, line, msg = nil)
          s = ">>> #{self.class.name}##{method}[#{line}] : #{msg}"
          if RUBY_PLATFORM == 'opal'
            Volt.logger.debug s
          else
            puts s
          end
        end
        model.singleton_class.send(:private, :debug)

      end

    end
  end
end
