# frozen_string_literal: true

module Sashiko
  module Adapters
    # Auto-instrumentation for Anthropic Ruby SDK (or any duck-typed client
    # exposing #create on a Messages-like resource).
    #
    # Attribute names follow OpenTelemetry GenAI semantic conventions:
    #   https://opentelemetry.io/docs/specs/semconv/gen-ai/
    #
    # Anthropic-specific prompt-cache metrics are namespaced under
    # gen_ai.anthropic.* since the spec does not yet cover them.
    module Anthropic
      # Immutable per-model pricing (USD per 1M tokens). Data values are
      # frozen and Ractor-shareable by default.
      Price = Data.define(:input, :output, :cache_write, :cache_read)

      # Snapshot as of 2026-04. Anthropic adds and retires models on its
      # own schedule and this table will go stale; override at runtime via
      # `Sashiko::Adapters::Anthropic.pricing = { ... }` when that happens.
      # The cost attribute is silently skipped for models not in this Hash.
      DEFAULT_PRICING = ::Ractor.make_shareable({
        "claude-opus-4-7"   => Price.new(input: 15.00, output: 75.00, cache_write: 18.75, cache_read: 1.50),
        "claude-sonnet-4-6" => Price.new(input:  3.00, output: 15.00, cache_write:  3.75, cache_read: 0.30),
        "claude-haiku-4-5"  => Price.new(input:  1.00, output:  5.00, cache_write:  1.25, cache_read: 0.10),
      })

      class << self
        attr_writer :pricing

        def pricing = @pricing ||= DEFAULT_PRICING

        # Idempotent: prepends Wrapper once per class, then returns the
        # class on every call so callers can chain and so a re-invocation
        # is a safe no-op rather than a silent nil.
        #
        # Pass tracer: to bind this instrumentation to a specific tracer
        # (e.g. a Ruby::Box-local tracer). Subsequent re-invocations with
        # a different tracer overwrite the previous binding so callers
        # can rebind without re-prepending.
        def instrument!(messages_class, tracer: nil)
          unless messages_class.instance_variable_get(:@__sashiko_instrumented)
            messages_class.prepend(Wrapper)
            messages_class.instance_variable_set(:@__sashiko_instrumented, true)
          end
          messages_class.instance_variable_set(:@__sashiko_tracer, tracer)
          messages_class
        end

        # Ruby 4.0 Ruby::Box variant: apply the prepend only inside the
        # given Box, so the monkey-patch does NOT leak into the main
        # Ruby process. Useful when multiple services in the same process
        # want to instrument Anthropic calls independently, or when you
        # want to A/B different adapter versions side-by-side.
        #
        # Requires the process to be started with RUBY_BOX=1.
        #
        #   box = Ruby::Box.new
        #   box.require "anthropic"
        #   Sashiko::Adapters::Anthropic.instrument_in_box!(box, "Anthropic::Messages")
        #
        #   # Main process's Anthropic::Messages remains untouched.
        def instrument_in_box!(box, messages_class_name)
          raise Sashiko::Box::NotEnabledError unless Sashiko::Box.enabled?
          # When OpenTelemetry is loaded inside the box, bind to the
          # box-local tracer explicitly so Wrapper doesn't fall back to
          # main's Sashiko.tracer. If OTel isn't loaded yet, fall through
          # with tracer: nil — Wrapper will resolve at call time, by
          # which point the caller has typically configured OTel.
          box.eval(<<~RUBY)
            require "sashiko/adapters/anthropic"
            klass = Object.const_get(#{messages_class_name.inspect})
            local_tracer = defined?(::OpenTelemetry) ?
              ::OpenTelemetry.tracer_provider.tracer("sashiko/anthropic") : nil
            Sashiko::Adapters::Anthropic.instrument!(klass, tracer: local_tracer)
          RUBY
        end

        # Map of response key to span attribute name. Iterating this once
        # is clearer than four near-identical case/in stanzas.
        RESPONSE_ATTRS = {
          id:    "gen_ai.response.id",
          model: "gen_ai.response.model",
        }.freeze

        USAGE_ATTRS = {
          input_tokens:                "gen_ai.usage.input_tokens",
          output_tokens:               "gen_ai.usage.output_tokens",
          cache_creation_input_tokens: "gen_ai.anthropic.cache_creation_input_tokens",
          cache_read_input_tokens:     "gen_ai.anthropic.cache_read_input_tokens",
        }.freeze

        def record_response(span, response)
          if (usage = response[:usage]).is_a?(Hash)
            set_usage_attributes(span, usage)
            set_cost(span, response[:model], usage)
            set_cache_hit_ratio(span, usage)
          end

          RESPONSE_ATTRS.each do |key, attr|
            response[key]&.then { |v| span.set_attribute(attr, v) }
          end

          case response[:stop_reason]
          in String | Symbol => reason
            span.set_attribute("gen_ai.response.finish_reasons", [reason.to_s])
          else
          end
        end

        private

        def set_usage_attributes(span, usage)
          USAGE_ATTRS.each do |key, attr|
            n = usage[key]
            span.set_attribute(attr, n) if n.is_a?(Integer)
          end
        end

        def set_cost(span, model, usage)
          return unless model
          price = pricing[model]
          return unless price

          input_toks  = usage[:input_tokens]                || 0
          output_toks = usage[:output_tokens]               || 0
          cache_write = usage[:cache_creation_input_tokens] || 0
          cache_read  = usage[:cache_read_input_tokens]     || 0

          cost = (input_toks  * price.input       +
                  output_toks * price.output      +
                  cache_write * price.cache_write +
                  cache_read  * price.cache_read) / 1_000_000.0
          span.set_attribute("gen_ai.usage.cost_usd", cost.round(6))
        end

        def set_cache_hit_ratio(span, usage)
          input_toks = usage[:input_tokens]            || 0
          cache_read = usage[:cache_read_input_tokens] || 0
          total = input_toks + cache_read
          return if total.zero?
          span.set_attribute("gen_ai.anthropic.cache_hit_ratio", (cache_read.to_f / total).round(4))
        end
      end

      module Wrapper
        def create(**params)
          attrs = { "gen_ai.system" => "anthropic", "gen_ai.operation.name" => "chat" }
          attrs["gen_ai.request.model"]       = params[:model]       if params.key?(:model)
          attrs["gen_ai.request.max_tokens"]  = params[:max_tokens]  if params.key?(:max_tokens)
          attrs["gen_ai.request.temperature"] = params[:temperature] if params.key?(:temperature)
          attrs["gen_ai.request.top_p"]       = params[:top_p]       if params.key?(:top_p)

          tracer = self.class.instance_variable_get(:@__sashiko_tracer) || Sashiko.tracer
          tracer.in_span("chat #{params[:model]}", attributes: attrs, kind: :client) do |span|
            response = super(**params)
            Anthropic.record_response(span, response)
            response
          rescue => e
            span.record_exception(e)
            span.status = OpenTelemetry::Trace::Status.error(e.message)
            raise
          end
        end
      end
    end
  end
end
