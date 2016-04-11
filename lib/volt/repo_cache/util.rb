module Volt
  module RepoCache
    module Util
      module_function

      def setter(getter)
        :"#{getter}="
      end

      def creator(getter)
        prefix_method(getter, 'new')
      end

      def adder(getter)
        prefix_method(getter, 'add')
      end

      def remover(getter)
        prefix_method(getter, 'remove')
      end

      def prefix_method(getter, prefix)
        :"#{prefix}_#{getter.to_s.singularize}"
      end

      def arrify(object)
        object.respond_to?(:to_a) ? object.to_a : [object]
      end

      def unsupported(method)
        fail "#{method} is an unsupported operation for #{self.class.name}"
      end

      def not_yet_implemented(method)
        fail "#{method} is not yet implemented for #{self.class.name}"
      end

      def subclass_responsibility(method)
        fail "#{method} is responsibility of #{self.class.name}"
      end

      def friends_only(__method__, caller)
        unless friend?(caller)
          fail "#{self.class.name}##{__method__} for Volt::RepoCache use only, not #{caller.class.name}"
        end
      end

      def friend?(object)
        if object
          if object.is_a?(Volt::Model)
            object.respond_to?(:patched_for_cache?)
          else
            (object.class.name =~ /^Volt::RepoCache/) == 0
          end
        else
          false
        end
      end

      def debug_level=(l)
        @debug_level = l
      end

      def debug_level
        @debug_level ||= 0
      end

      def debug_method_missing=(v)
        @debug_method_missing = v
      end

      def debug_method_missing?
        !!@debug_method_missing
      end

      def debug(level, proc)
        if level == 0 || level <= debug_level
          file, line, method, msg = proc.call
          s = "#{file}[#{line}] #{self.is_a?(Class) ? (self.name + '#') : self.class.name}##{method}"
          s = s + " >> #{msg}" if msg
          if RUBY_PLATFORM == 'opal'
            `console.log(s)`
          else
            puts s
          end
        end
      end

      def time(method, line, msg = nil)
        t1 = Time.now
        r = yield
        t2 = Time.now
        debug(method, line, "#{msg} : took #{t2 - t1} seconds")
        r
      end
    end
  end
end