# TODO: implement locking, atomic transactions, ...

module Volt
  module RepoCache
    class Cache
      include Volt::RepoCache::Util


      attr_reader :options, :collections, :repo
      attr_reader :loaded # returns a promise

      # Create a cache for a given Volt repo (store, page, local_store...)
      # and the given collections within it.
      #
      # If no repo given then Volt.current_app.store will be used.
      #
      # Collections is an array of hashes each with a collection
      # name as key, and a hash of options as value.
      # Collection options are:
      #   :where => query (as for store._collection.where(query))
      #   :filter => a proc receiving a model as arg, returns true to load
      #
      # The cache should be used until the 'loaded' promise
      # resolves.
      #
      # For example, to cache all users:
      #
      #   RepoCache.new(collections: [:_users]).loaded.then do |cache|
      #     puts "cache contains #{cache._users.size} users"
      #   end
      #
      # Call #flush! to flush all changes to the repo.
      # Call #clear when finished with the cache to help
      # garbage collection.
      #
      # TODO:
      # read_only should be inherited by has_... targets
      #
      def initialize(**options)
        @repo = options.delete(:repo) || Volt.current_app.store
        @collection_options = options.delete(:collections) || {}
        load
      end

      def persistor
        @repo.persistor
      end

      def query(collection_name, args)
        collections[collection_name].query(args)
      end

      def method_missing(method, *args, &block)
        collection = @collections[method]
        super unless collection
        collection
      end

      # Clear all caches, circular references, etc
      # when cache no longer required - can't be
      # used after this.
      def clear
        # debug __method__, __LINE__
        @collections.each do |name, collection|
          collection.send(:uncache)
        end
        @collections = {}

        # TODO: this is not nice, but bad things happen if we don't clear the repo persistor's identity map
        # -> ensure we don't leave patched models lying around
        # debug __method__, __LINE__, "calling @repo.persistor.clear_identity_map "
        # @repo.persistor.clear_identity_map # otherwise error if new customer add via repo_cache
      end

      # Flush all cached collections and in turn
      # all their models. Flushing performs
      # inserts, updates or destroys as required.
      # Returns a promise with this cache as value
      # or error(s) if any occurred.
      def flush!
        flushes = collections.values.map {|c| c.flush! }
        Promise.when(*flushes).then { self }
      end

      private

      def load
        @collections = {}
        promises = []
        @collection_options.each do |given_name, options|
          name = collection_name(given_name)
          collection = Collection.new(cache: self, name: name, options: options)
          @collections[name] = collection
          promises << collection.loaded
        end
        @loaded = Promise.when(*promises).then do
          self
        end
      end

      def collection_name(given_name)
        n = given_name.to_s.underscore.pluralize
        if RUBY_PLATFORM == 'opal'
          if n[-2,2] == 'ss'
            rx = given_name.sub(/s$/i, 's')
            s = "#{__FILE__}[#{__LINE__}]:#{self.class.name}##{__method__}: given_name=#{given_name} n=#{n} rx=#{rx}"
            `console.log(s)`
            n = rx
          end
        end
        n = '_' + n unless n[0] == '_'
        n.to_sym
      end
    end
  end
end
