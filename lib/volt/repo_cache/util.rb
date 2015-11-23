module Volt
  module RepoCache
    module Util
      module_function

      def setter(getter)
        (getter.to_s + '=').to_sym
      end

      def adder(getter)
        ('add_' + getter.to_s.singularize).to_sym
      end

      def remover(getter)
        ('remove_' + getter.to_s.singularize).to_sym
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
          fail "#{self.class.name}##{__method__} for Volt::RepoCache use only"
        end
      end

      def friend?(object)
        object ? (object.class.name =~ /^Volt::RepoCache/) == 0 : false
      end

      def debug(method, line, msg = nil)
        s = ">>> #{self.class.name}##{method}[#{line}] : #{msg}"
        # if RUBY_PLATFORM == 'opal'
          Volt.logger.debug s
        # else
        #  puts s
        # end
      end

    end
  end
end