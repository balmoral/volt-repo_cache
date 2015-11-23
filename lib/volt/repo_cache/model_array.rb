require 'volt/reactive/reactive_array'

module Volt
  module RepoCache
    class ModelArray
      include Volt::RepoCache::Util

      def initialize(observer: nil, contents: [])
        @observers = [observer]
        @contents = Volt::ReactiveArray.new(contents)
      end

      def add_observer(o, caller: nil)
        friends_only(__method__, caller)
        @observers << o unless @observers.detect{|e|e.object_id == o.object_id}
      end

      def remove_observer(o, caller: nil)
        friends_only(__method__, caller)
        i = @observers.find_index{|e|e.object_id == o.object_id}
        @observers.delete_at(i) if i
      end

      def clear_observers(caller: nil)
        friends_only(__method__, caller)
        @observers = []
      end

      def delete_at(index, notify: true, caller: nil)
        friends_only(__method__, caller)
        model = @contents.delete_at(index)
        notify_observers(:remove, model) if notify && model
        model
      end

      def delete(model, notify: true, caller: nil)
        friends_only(__method__, caller)
        i = find_index(model)
        delete_at(i, caller: caller, notify: notify) if i
      end

      def clear(caller: nil)
        friends_only(__method__, caller)
        @contents.clear
      end

      def index(*args, &block)
        @contents.index(*args, &block)
      end

      def to_a
        @contents.to_a
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

      # Appends an object to the collection.
      # Returns self.
      def append(model, notify: true, caller: nil)
        friends_only(__method__, caller)
        @contents.append(model)
        notify_observers(:add, model) if notify
        self
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

      def reduce(&block)
        @contents.reduce(&block)
      end

      alias_method :inject, :reduce

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
        remove(model, error_if_absent: false, caller: caller)
      end

      # like delete but for internal use
      def remove(model, error_if_absent: true, caller: nil)
        friends_only(__method__, caller)
        index = index {|e| e.id == model.id }
        if index
          result = delete_at(index, caller: self)
          # debug __method__, __LINE__, "deleted #{result.class.name} #{result.id}"
          result
        elsif error_if_absent
          msg = "could not find #{model.class.name} with id #{model.id} to delete"
          # debug __method__, __LINE__, msg
          raise RuntimeError, msg
        end
      end

      private

      def notify_observers(action, model)
        debug __method__, __LINE__, "action=#{action} model=#{model} @observers.size=#{@observers.size}"
        @observers.each do |o|
          if o.respond_to?(:observe)
            debug __method__, __LINE__, "calling observer on #{o}"
            o.observe(action, model, caller: self)
          else
            raise RuntimeError, "observer #{o} must respond to :observe"
          end
        end
      end

    end
  end
end
