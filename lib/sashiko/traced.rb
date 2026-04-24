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
    # Immutable trace configuration for a single method. Frozen Data value,
    # Ractor-shareable — the overlay's closure captures this record instead
    # of an ad-hoc bag of locals.
    Options = Data.define(:span_name, :kind, :attributes, :record_args, :method_name, :class_name)

    # @type self: Module
    def trace(method_name, name: nil, kind: :internal, attributes: nil, record_args: false)
      options = Options.new(
        span_name: name || "#{self.name || "anon"}##{method_name}",
        kind:,
        attributes:,
        record_args:,
        method_name: method_name.to_sym,
        class_name: self.name,
      )
      Traced.weave(Traced.overlay_for(self), options)
    end

    # Trace every instance method matching `pattern` defined ON this class.
    # Must be called AFTER the method defs so they are visible to
    # instance_methods(false).
    # @type self: Module
    def trace_all(matching:, kind: :internal, record_args: false)
      overlay = Traced.overlay_for(self)
      instance_methods(false)
        .select { |m| m.to_s.match?(matching) }
        .reject { |m| overlay.instance_methods(false).include?(m) }
        .each   { |m| trace(m, kind:, record_args:) }
    end

    class << self
      # One prepended module per target class; we redefine on top of it when
      # the same method is re-traced. This keeps super chains intact.
      def overlay_for(klass) = klass.instance_variable_get(:@__sashiko_overlay) || Traced.install_overlay(klass)

      def install_overlay(klass)
        Module.new.tap do |m|
          klass.prepend(m)
          klass.instance_variable_set(:@__sashiko_overlay, m)
        end
      end

      def weave(overlay, options)
        overlay.define_method(options.method_name) do |*args, **kwargs, &block|
          attrs = Traced.build_attributes(args, kwargs, options)
          Sashiko.tracer.in_span(options.span_name, attributes: attrs, kind: options.kind) do |span|
            super(*args, **kwargs, &block)
          rescue => e
            span.record_exception(e)
            span.status = OpenTelemetry::Trace::Status.error(e.message)
            ::Kernel.raise
          end
        end
      end

      def build_attributes(args, kwargs, options)
        attrs = { "code.function" => options.method_name.to_s } #: Hash[String, untyped]
        attrs["code.namespace"]  = options.class_name if options.class_name
        attrs["code.args.count"] = args.length + kwargs.length if options.record_args

        extra = case options.attributes
                in Proc => fn then fn.arity.zero? ? fn.call : fn.call(*args, **kwargs)
                in Hash => h  then h
                else nil
                end

        extra&.each { |k, v| attrs[k.to_s] = v }
        attrs
      end
    end
  end
end
