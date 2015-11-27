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
      # Options are:
      # :where => query (as for store._collection.where(query))
      # ...
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
      def initialize(repo: nil, **options)
        @repo = repo || Volt.current_app.store
        @options = options
        debug __method__, __LINE__, "@options = #{@options}"
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
          # debug __method__, __LINE__, "name=#{name} collection=#{collection}"
          collection.send(:break_references)
        end
        @collections = {}
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
        @options.each do |given_name, options|
          name = collection_name(given_name)
          debug __method__, __LINE__
          collection = Collection.new(cache: self, name: name, options: options)
          debug __method__, __LINE__
          @collections[name] = collection
          promises << collection.loaded
        end
        @loaded = Promise.when(*promises).then { self }
        debug __method__, __LINE__, "@loaded => #{@loaded.class.name}:#{@loaded.value.class.name}"
      end

      def collection_name(given_name)
        n = given_name.to_s.underscore.pluralize
        n = '_' + n unless n[0] == '_'
        n.to_sym
      end
    end
  end
end
