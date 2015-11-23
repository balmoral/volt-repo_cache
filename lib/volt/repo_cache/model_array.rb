require 'volt/reactive/reactive_array'

module Volt
  module RepoCache
    class ModelArray < Volt::ReactiveArray
      include Volt::RepoCache::Util

      def initialize(observers: [], contents: [])
        super(contents)
        @observers = observers.dup
      end

      def add_observer(o)
        @observers << o unless @observers.detect{|e|e.object_id == o.object_id}
      end

      def remove_observer(o)
        i = @observers.find_index{|e|e.object_id == o.object_id}
        @observers.delete_at(i) if i
      end

      def +(other)
        unsupported(__method__)
      end

      def []=(index, model)
        prior = self[index]
        super
        notify(:remove, prior) if prior
        notify(:add, model) if model
        model
      end

      def delete_at(index)
        model = super
        notify(:remove, model) if model
        model
      end

      def delete(model)
        i = find_index(model)
        delete_at(i) if i
      end

      def clear(caller: nil)
        friends_only(__method__, caller)
        super()
      end

      def insert(index, *objects)
        unsupported(__method__)
      end

      # Appends an object to the collection.
      # Returns self.
      def <<(model)
        append(model)
      end

      # Appends an object to the collection.
      # Returns self.
      def append(model)
        super
        notify(:add, model)
        self
      end

      def concat(other)
        unsupported(__method__)
      end

      # Query is simple for now:
      # - a hash keys and values to match by equality
      # - or a select block
      # TODO: would prefer a splat to the hash,
      # but Opal fails to parse calls with **splats
      def query(args = nil, &block)
        if args.nil? || args.empty?
          if block
            select &block
          else
            raise ArgumentError, 'query requires splat of key-value pairs, or a select block'
          end
        elsif args.size == 1
          k, v = args.first
          select {|e| e.send(k) == v}
        else
          query do |e|
            match = true
            args.each do |k, v|
              unless e.send(k) == v
                match = false
                break
              end
            end
            match
          end
        end
      end

      alias_method :where, :query

      # like delete but for internal use
      def remove_if_present(model, caller: nil)
        friends_only(__method__, caller)
        remove(model, error_if_absent: false)
      end

      # like delete but for internal use
      def remove(model, error_if_absent: true, caller: nil)
        friends_only(__method__, caller)
        index = index {|e| e.id == model.id }
        if index
          result = delete_at(index)
          # debug __method__, __LINE__, "deleted #{result.class.name} #{result.id}"
          result
        elsif error_if_absent
          msg = "could not find #{model.class.name} with id #{model.id} to delete"
          # debug __method__, __LINE__, msg
          raise RuntimeError, msg
        end
      end

      private

      def notify(action, model)
        @observers.each do |o|
          o.notify(action, model)
        end
      end

    end
  end
end
