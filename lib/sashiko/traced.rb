# frozen_string_literal: true

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
    #
    # `static_attrs` is a frozen Hash holding the attributes that don't
    # vary per call (`code.function`, `code.namespace`). Pre-baked at
    # trace declaration time so build_attributes only allocates for the
    # genuinely dynamic parts.
    Options = Data.define(:span_name, :kind, :attributes, :record_args, :method_name, :class_name, :tracer, :static_attrs)

    # @type self: Module
    def trace(method_name, name: nil, kind: :internal, attributes: nil, record_args: false, tracer: nil)
      method_sym = method_name.to_sym
      class_name = self.name
      static_attrs = { "code.function" => method_sym.to_s }
      static_attrs["code.namespace"] = class_name if class_name
      static_attrs.freeze

      options = Options.new(
        span_name: name || "#{class_name || "anon"}##{method_sym}",
        kind:,
        attributes:,
        record_args:,
        method_name: method_sym,
        class_name:,
        tracer:,
        static_attrs:,
      )
      Traced.weave(Traced.overlay_for(self), options)
    end

    # Trace every instance method matching `pattern` defined ON this class.
    # Must be called AFTER the method defs so they are visible to
    # instance_methods(false).
    # @type self: Module
    def trace_all(matching:, kind: :internal, record_args: false, tracer: nil)
      overlay = Traced.overlay_for(self)
      already_overlaid = overlay.instance_methods(false)
      instance_methods(false)
        .select { |m| m.to_s.match?(matching) }
        .reject { |m| already_overlaid.include?(m) }
        .each   { |m| trace(m, kind:, record_args:, tracer:) }
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
          tracer = options.tracer || Sashiko.tracer
          tracer.in_span(options.span_name, attributes: attrs, kind: options.kind) do |span|
            super(*args, **kwargs, &block)
          rescue => e
            span.record_exception(e)
            span.status = OpenTelemetry::Trace::Status.error(e.message)
            ::Kernel.raise
          end
        end
      end

      def build_attributes(args, kwargs, options)
        extra = case options.attributes
                in Proc => fn then fn.arity.zero? ? fn.call : fn.call(*args, **kwargs)
                in Hash => h  then h
                else nil
                end

        # Fast path: nothing dynamic. Return the pre-baked frozen Hash
        # directly — OTel SDK copies it before storing on the Span.
        return options.static_attrs unless options.record_args || extra

        attrs = options.static_attrs.dup #: Hash[String, untyped]
        attrs["code.args.count"] = args.length + kwargs.length if options.record_args
        extra&.each { |k, v| attrs[k.to_s] = v }
        attrs
      end
    end
  end
end
