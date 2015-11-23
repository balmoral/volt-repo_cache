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
        collection.associations.each_value do |assoc|
          foreign_name = assoc.foreign_name
          # create get methods
          model.define_singleton_method(foreign_name) do
            get_association(assoc)
          end
          # create set methods
          model.define_singleton_method(setter(foreign_name)) do |model_or_array|
            set_association(assoc, model_or_array)
          end
          # create add and remove methods for has_many association
          if assoc.has_many?
            model.define_singleton_method(adder(foreign_name)) do |other|
              add_to_many(assoc, other)
            end
            model.define_singleton_method(remover(foreign_name)) do |other|
              remove_from_many(assoc, other)
            end
          end
        end

        # Use respond_to?(:patched_for_cache?) to determine
        # whether a model's behaviour has been patched here
        # to operate in the cache.
        def model.patched_for_cache?
          true
        end

        def model.marked_for_destruction?
          @marked_for_destruction
        end

        # Marks the model and all its 'has_' associations
        # for destruction when cache is flushed.
        def model.mark_for_destruction!
          # prevent collection going in circles on this
          # (we don't know whether initial request was to
          # self or to collection which holds self)
          unless @marked_for_destruction
            debug __method__, __LINE__, "marking for destruction"
            @marked_for_destruction = true
            @collection.mark_model_for_destruction(self)
            mark_associations_for_destruction
          end
        end

        def model.cache
          @collection.cache
        end

        def model.lock
          raise RuntimeError, 'lock support coming'
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
        #   and all its (has_) associations
        #
        # Returns a promise when done.
        #
        # WARNING
        # - flush! is not (yet) an atomic transaction
        # - any part of it may fail without unwinding the whole
        def model.flush!
          if @marked_for_destruction
            # debug __method__, __LINE__, "marked for destruction so call destroy"
            destroy(caller: self)
          else
            if new? || dirty?
              debug __method__, __LINE__
              if new?
                # debug __method__, __LINE__
                @collection.repo_collection << self
              else
                # debug __method__, __LINE__
                save!(caller: self)
              end
            else
              # neither new nor dirty but
              # stay in the promise chain
              Promise.value(self)
            end.then do
              # debug __method__, __LINE__
              flush_associations!
            end
          end.then do
            self
          end
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

        # Returns true if proxy is buffered and the
        # buffer has changed from original model.
        # If proxy is new model return true.
        # Assumes fields defined for model.
        # Does not check associations.
        def model.dirty?
          if buffer?
            # fields_data is a core Volt class method
            self.class.fields_data.keys.each do |field|
              return true if changed?(field)
            end
          end
          new?
        end

        def model.break_references
          @associations.clear
          @collection = @associations = nil
        end

        # Should only be called by the associated foreign RepoCache::Collection.
        #
        def model.refresh_association(foreign_association)
          debug __method__, __LINE__, "foreign_association=#{foreign_association.local_name_plural}"
          association = @collection.associations[foreign_collection.name]
          debug __method__, __LINE__, "association=#{association.inspect}"
          # simply refresh the association query
          result = get_association(association)
          debug __method__, __LINE__, "#{self} association=#{association} result=#{result}"
        end

        # ######################################
        # FOLLOWING ARE INTENDED FOR PRIVATE USE
        # Don't call directly. Should be private.
        # ######################################

        # Ensure save! is not being called by anyone else but self.
        def model.save!(caller: nil)
          unless caller == self
            raise RuntimeError, 'use #flush!, cannot save! directly'
          end
          super()
        end

        # Deletes the underlying model the database.
        # NB in Volt 0.9.6 there's a problem with destroy
        # if the MESSAGE_BUS is on and there's another connection
        # (e.g. console) running.
        # Returns a promise with destroyed model proxy as value.
        def model.destroy(caller: nil)
          debug __method__, __LINE__
          unless caller == self
            raise RuntimeError, 'cached models should be marked for destruction, cannot destroy directly'
          end
          if new?
            Promise.error("cannot delete new model proxy for #{@model.class.name} #{@model.id}")
          else
            debug __method__, __LINE__
            promise = super()
            debug __method__, __LINE__, "after real destroy: #{self.class.name} #{id}"
            promise.then do |m|
              debug __method__, __LINE__, "destroy promise resolved to #{m}"
              @collection.remove(self, error_if_absent: true, caller: self)
              @collection.destroyed(self)
              break_references
              self
            end
          end
        end

        def model.get_association(assoc)
          foreign_name = assoc.foreign_name
          prior = @associations[foreign_name]
          local_id = send(assoc.local_id_field)
          debug __method__, __LINE__, "assoc=#{assoc.inspect}"
          foreign_id_field = assoc.foreign_id_field
          debug __method__, __LINE__, "foreign_id_field=#{foreign_id_field}"
          result = if prior && match?(prior, foreign_id_field, local_id)
            prior
          else
            q = {foreign_id_field => local_id}
            result = assoc.foreign_collection.query(q) || []
            @associations[foreign_name] = assoc.has_many? ? ModelArray.new(contents: result) : result.first
          end
          result
        end

        # NB we don't update local @associations.
        # We wait to be notified by associated collections
        # of changes we make to them. This ensures that
        # if changes are made to those collections that
        # have not gone through this method, that everything
        # is still in sync.
        def model.set_association(assoc, other)
          validate_patched_for_cache(other)
          if assoc.belongs_to?
            # Set the local id to the foreign id
            send(Util.setter(assoc.local_id_field), other.id)
          else
            prior = get_association(assoc)
            if assoc.has_one?
              set_one(assoc, other, prior)
            elsif assoc.has_many?
              set_many(assoc, other, prior)
            else
              raise RuntimeError, "set_association cannot handle #{assoc.inspect}"
            end
          end
        end

        def model.validate_patched_for_cache(model_or_array)
          Util.arrify(model_or_array).each do |other|
            unless other.respond_to?(:patched_for_cache?)
              raise RuntimeError, "#{other} must be loaded into or created via cache"
            end
          end
        end

        def model.set_one(assoc, other, prior)
          unless other.is_a?(assoc.foreign_model_class)
            raise RuntimeError, "#{assoc.foreign_name} must be a #{assoc.foreign_model_class_name}"
          end
          prior.mark_for_destruction! if prior
          # Set the foreign_id of the new_value to this model's id.
          set_foreign_id(assoc, other)
          # Add to cache if not already there, which will raise an exception
          # if the new_Value is not new or is not the appropriate class.
          assoc.foreign_collection.append(other, error_if_present: false)
        end

        def model.set_many(assoc, new_values, prior_values)
          unless new_values.respond_to?(:to_a)
            raise RuntimeError, "value for setting has_many #{assoc.name} must respond to :to_a"
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

        # Add model to has_many association if not already there.
        # Will raise an exception if the new association
        # is not new or is not the appropriate class.
        def model.add_to_many(assoc, other)
          set_foreign_id(assoc, other)
          assoc.foreign_collection.append(other, error_if_present: false)
        end

        # Mark the given associated model for destruction if
        # it's foreign id equals this model's id. Return the
        # the marked model. Raises exception if the given
        # associated model does not belongs to this model.
        def model.remove_from_many(assoc, other)
          validate_ownership(assoc, other)
          other.mark_for_destruction!
        end

        # Sets the appropriate foreign_id of the given model
        # to this model's id. Raises an exception if the
        # foreign_id is already set and not this model's
        # (i.e. if the associate belongs to another model).
        def model.set_foreign_id(assoc, other)
           validate_ownership(assoc, other, require_foreign_id: false) do |prior_foreign_id|
            # after validation we can be sure prior_foreign_id == self.id
            debug __method__, __LINE__
            unless prior_foreign_id
              other.send(Util.setter(assoc.foreign_id_field), id)
            end
            debug __method__, __LINE__
          end
        end

        # Validate that the appropriate foreign_id in the associate
        # matches this model's id. If the associate's foreign_id is
        # nil (not yet set) raise an error if require_foreign_id is
        # true. If the associate's foreign_id is set, raise an error
        # if it does not match this model's id. Otherwise return true
        # if the foreign id is not nil. Yield to given block if provided.
        def model.validate_ownership(assoc, other, require_foreign_id: true, &block)
          debug __method__, __LINE__
          check = other.send(assoc.foreign_id_field)
          debug __method__, __LINE__
          if (check && check != self.id) || (require_foreign_id && check.nil?)
            raise RuntimeError, "#{other} should belong to #{self} or no-one else"
          end
          yield(check) if block
        end

        # Returns whether the id in the foreign_id_field
        # matches the given local id.  If the target is
        # an array then we check whether it's first element
        # matches (or if it's empty assume true?).
        def model.match?(other, foreign_id_field, local_id)
          target = other.respond_to?(:to_a) ? other.first : other
          target ? target.send(foreign_id_field) == local_id : true
        end

        # Calls flush on each has_one and has_many association.
        # Returns a single promise which collates all promises
        # from flushing associates.
        def model.flush_associations!
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

        # Marks all associated models for destruction
        def model.mark_associations_for_destruction
          @collection.associations.values.each do |assoc|
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

        def model.debug(method, line, msg = nil)
          s = ">>> #{self.class.name}##{method}[#{line}] : #{msg}"
          if RUBY_PLATFORM == 'opal'
            Volt.logger.debug s
          else
            puts s
          end
        end

        model
      end

    end
  end
end
