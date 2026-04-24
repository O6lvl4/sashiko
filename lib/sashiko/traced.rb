module Sashiko
  # Declarative span instrumentation via Module#prepend.
  #
  #   class OrderService
  #     extend Sashiko::Traced
  #
  #     trace :process, attributes: ->(order) { { "order.id" => order.id } }
  #
  #     def process(order); ...; end
  #   end
  module Traced
    def trace(method_name, name: nil, kind: :internal, attributes: nil, record_args: false)
      method_name = method_name.to_sym
      span_name = name || "#{self.name || "anon"}##{method_name}"
      overlay = Traced.overlay_for(self)
      Traced.define_wrapper(overlay, method_name, span_name, kind, attributes, record_args, self.name)
    end

    # Trace every instance method matching `pattern` that's currently
    # defined on this class. Only matches methods defined ON this class
    # (not inherited), and skips those already on the sashiko overlay.
    #   trace_all matching: /^handle_/
    #   trace_all matching: /./, kind: :internal
    def trace_all(matching:, kind: :internal, record_args: false)
      overlay = Traced.overlay_for(self)
      instance_methods(false).each do |m|
        next unless m.to_s.match?(matching)
        next if overlay.instance_methods(false).include?(m)
        trace(m, kind: kind, record_args: record_args)
      end
    end

    class << self
      # One prepended module per target class; we redefine on top of it when
      # the same method is re-traced. This keeps super chains intact.
      def overlay_for(klass)
        klass.instance_variable_get(:@__sashiko_overlay) || begin
          overlay = Module.new
          klass.prepend(overlay)
          klass.instance_variable_set(:@__sashiko_overlay, overlay)
          overlay
        end
      end

      def define_wrapper(overlay, method_name, span_name, kind, attributes_fn, record_args, class_name)
        overlay.define_method(method_name) do |*args, **kwargs, &block|
          tracer = Sashiko.tracer
          attrs = Traced.build_attributes(self, args, kwargs, attributes_fn, record_args, method_name, class_name)
          tracer.in_span(span_name, attributes: attrs, kind: kind) do |span|
            begin
              super(*args, **kwargs, &block)
            rescue => e
              span.record_exception(e)
              span.status = OpenTelemetry::Trace::Status.error(e.message)
              raise
            end
          end
        end
      end

      def build_attributes(receiver, args, kwargs, attributes_fn, record_args, method_name, class_name)
        result = { "code.function" => method_name.to_s }
        result["code.namespace"] = class_name if class_name
        if record_args
          result["code.args.count"] = args.length + kwargs.length
        end
        case attributes_fn
        when Proc
          extra = attributes_fn.arity.zero? ? receiver.instance_exec(&attributes_fn) : attributes_fn.call(*args, **kwargs)
          result.merge!(stringify_keys(extra)) if extra.is_a?(Hash)
        when Hash
          result.merge!(stringify_keys(attributes_fn))
        end
        result
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end
  end
end
