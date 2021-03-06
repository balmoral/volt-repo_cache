require 'volt/reactive/reactive_array'

module Volt
  module RepoCache
    class ModelArray
      include Volt::RepoCache::Util

      # for benefit of Volt::Watch
      def self.reactive_array?
        true
      end

      def initialize(observer: nil, contents: nil)
        @contents = Volt::ReactiveArray.new(contents || [])
        @id_hash = {}
        @contents.each do |e|
          @id_hash[e.id] = e
        end
      end

      def reactive_array?
        self.class.reactive_array?
      end

      # subclasses may override if interested.
      def observe(action, model)
        # no op
      end

      def index(*args, &block)
        @contents.index(*args, &block)
      end

      def to_a
        # not sure what reactive array does
        # so map contents into normal array
        @contents.map{|e|e}
      end

      def size
        @contents.size
      end

      def [](index)
        @contents[index]
      end

      def any?
        @contents.any?
      end

      def empty?
        @contents.empty?
      end

      def detect(*args, &block)
        @contents.detect(*args, &block)
      end

      def each(&block)
        @contents.each(&block)
      end

      def each_with_index(&block)
        @contents.each_with_index(&block)
      end

      def first
        @contents.first
      end

      def last
        @contents.last
      end

      def count(&block)
        # count returns promise in Volt::ArrayModel, so do here
        if block
          result = 0
          @contents.each do |e|
            result += 1 if block.call(e)
          end
          result
        else
          @contents.size
        end
      end

      def sort(&block)
        @contents.sort(&block)
      end

      def select(&block)
        @contents.select(&block)
      end

      def reject(&block)
        @contents.reject(&block)
      end

      def collect(&block)
        @contents.collect(&block)
      end

      alias_method :map, :collect

      def reduce(seed, &block)
        @contents.reduce(seed, &block)
      end

      alias_method :inject, :reduce

      # Query is simple for now:
      # - a hash of keys and values to match by equality
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
          if k == :id
            [@id_hash[v]]
          else
            select {|e| e.send(k) == v}
          end
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

      private

      def __delete_at__(index, notify: true)
        model = @contents.delete_at(index)
        if model
          @id_hash.delete(model.id)
          observe(:remove, model) if notify
        end
        model
      end

      def __delete__(model, notify: true)
        i = find_index(model)
        __delete_at__(i, notify: notify) if i
      end

      def __clear__
        @contents.clear
        @id_hash.clear
      end

      def __remove_if_present__
        __remove__(model, error_if_absent: false)
      end

      def __remove__(model, error_if_absent: true)
        index = index {|e| e.id == model.id }
        if index
          __delete_at__(index)
        elsif error_if_absent
          msg = "could not find #{model.class.name} with id #{model.id} to delete"
          raise RuntimeError, msg
        end
      end

      def __append__(model, notify: true)
        @contents.append(model)
        @id_hash[model.id] = model
        observe(:add, model) if notify
        self
      end

    end
  end
end
