require 'volt/reactive/reactive_array'

module Volt
  module RepoCache
    class ModelArray
      include Volt::RepoCache::Util

      def initialize(observer: nil, contents: [])
        @contents = Volt::ReactiveArray.new(contents)
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
        @contents.count(&block)
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

      private

      def __delete_at__(index, notify: true)
        model = @contents.delete_at(index)
        observe(:remove, model) if notify && model
        model
      end

      def __delete__(model, notify: true)
        i = find_index(model)
        __delete_at__(i, notify: notify) if i
      end

      def __clear__
        @contents.clear
      end

      def __remove_if_present__
        __remove__(model, error_if_absent: false)
      end

      def __remove__(model, error_if_absent: true)
        index = index {|e| e.id == model.id }
        if index
          result = __delete_at__(index)
          # debug __method__, __LINE__, "deleted #{result.class.name} #{result.id}"
          result
        elsif error_if_absent
          msg = "could not find #{model.class.name} with id #{model.id} to delete"
          # debug __method__, __LINE__, msg
          raise RuntimeError, msg
        end
      end

      def __append__(model, notify: true)
        @contents.append(model)
        observe(:add, model) if notify
        self
      end

    end
  end
end
