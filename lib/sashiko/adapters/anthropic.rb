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
      # Approximate USD per 1M tokens. Users should override via
      # Sashiko::Adapters::Anthropic.pricing = {...} to match current rates.
      DEFAULT_PRICING = {
        "claude-opus-4-7"     => { input: 15.00, output: 75.00, cache_write: 18.75, cache_read: 1.50 },
        "claude-sonnet-4-6"   => { input:  3.00, output: 15.00, cache_write:  3.75, cache_read: 0.30 },
        "claude-haiku-4-5"    => { input:  1.00, output:  5.00, cache_write:  1.25, cache_read: 0.10 },
      }.freeze

      class << self
        attr_writer :pricing

        def pricing
          @pricing ||= DEFAULT_PRICING.dup
        end

        def instrument!(messages_class)
          return if messages_class.instance_variable_get(:@__sashiko_instrumented)
          messages_class.prepend(Wrapper)
          messages_class.instance_variable_set(:@__sashiko_instrumented, true)
          messages_class
        end

        def record_response(span, response)
          usage = dig(response, :usage)
          input_toks  = dig(usage, :input_tokens)
          output_toks = dig(usage, :output_tokens)
          cache_write = dig(usage, :cache_creation_input_tokens)
          cache_read  = dig(usage, :cache_read_input_tokens)

          set(span, "gen_ai.usage.input_tokens",  input_toks)
          set(span, "gen_ai.usage.output_tokens", output_toks)
          set(span, "gen_ai.anthropic.cache_creation_input_tokens", cache_write)
          set(span, "gen_ai.anthropic.cache_read_input_tokens",     cache_read)
          set(span, "gen_ai.response.id",    dig(response, :id))
          set(span, "gen_ai.response.model", dig(response, :model))

          stop_reason = dig(response, :stop_reason)
          span.set_attribute("gen_ai.response.finish_reasons", [stop_reason.to_s]) if stop_reason

          model = dig(response, :model) || span.instance_variable_get(:@__req_model)
          cost = estimate_cost(model, input_toks, output_toks, cache_write, cache_read)
          set(span, "gen_ai.usage.cost_usd", cost)

          if input_toks && cache_read && input_toks.positive?
            ratio = cache_read.to_f / (input_toks + cache_read)
            span.set_attribute("gen_ai.anthropic.cache_hit_ratio", ratio.round(4))
          end
        end

        def estimate_cost(model, input_toks, output_toks, cache_write, cache_read)
          price = pricing[model]
          return nil unless price
          total = 0.0
          total += (input_toks  || 0) * price[:input]       / 1_000_000.0
          total += (output_toks || 0) * price[:output]      / 1_000_000.0
          total += (cache_write || 0) * price[:cache_write] / 1_000_000.0
          total += (cache_read  || 0) * price[:cache_read]  / 1_000_000.0
          total.round(6)
        end

        def dig(obj, key)
          return nil if obj.nil?
          return obj[key]      if obj.is_a?(Hash) && obj.key?(key)
          return obj[key.to_s] if obj.is_a?(Hash) && obj.key?(key.to_s)
          return obj.public_send(key) if obj.respond_to?(key)
          nil
        end

        def set(span, key, value)
          span.set_attribute(key, value) unless value.nil?
        end
      end

      module Wrapper
        def create(**params)
          tracer = Sashiko.tracer
          model  = params[:model]
          attrs  = {
            "gen_ai.system"            => "anthropic",
            "gen_ai.operation.name"    => "chat",
            "gen_ai.request.model"     => model,
          }
          attrs["gen_ai.request.max_tokens"]  = params[:max_tokens]  if params.key?(:max_tokens)
          attrs["gen_ai.request.temperature"] = params[:temperature] if params.key?(:temperature)
          attrs["gen_ai.request.top_p"]       = params[:top_p]       if params.key?(:top_p)

          tracer.in_span("chat #{model}", attributes: attrs, kind: :client) do |span|
            begin
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
end
