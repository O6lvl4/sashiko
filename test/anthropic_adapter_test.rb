require_relative "test_helper"
require "sashiko/adapters/anthropic"

class AnthropicAdapterTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_instruments_create_with_genai_semconv_attributes
    stub = Class.new do
      def create(**params)
        {
          id: "msg_abc",
          model: params[:model],
          stop_reason: "end_turn",
          usage: {
            input_tokens: 100,
            output_tokens: 50,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
          },
        }
      end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    stub.new.create(model: "claude-sonnet-4-6", max_tokens: 1024, messages: [])
    span = @exporter.finished_spans.last

    assert_equal "chat claude-sonnet-4-6", span.name
    assert_equal "anthropic",               span.attributes["gen_ai.system"]
    assert_equal "chat",                    span.attributes["gen_ai.operation.name"]
    assert_equal "claude-sonnet-4-6",       span.attributes["gen_ai.request.model"]
    assert_equal 1024,                      span.attributes["gen_ai.request.max_tokens"]
    assert_equal 100,                       span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 50,                        span.attributes["gen_ai.usage.output_tokens"]
    assert_equal "msg_abc",                 span.attributes["gen_ai.response.id"]
    assert_equal ["end_turn"],              span.attributes["gen_ai.response.finish_reasons"]
  end

  def test_estimates_cost_from_pricing_table
    stub = Class.new do
      def create(**params)
        {
          model: params[:model],
          stop_reason: "end_turn",
          usage: { input_tokens: 1_000_000, output_tokens: 1_000_000 },
        }
      end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    stub.new.create(model: "claude-sonnet-4-6", max_tokens: 10, messages: [])
    span = @exporter.finished_spans.last

    # 1M input * $3 + 1M output * $15 = $18
    assert_equal 18.0, span.attributes["gen_ai.usage.cost_usd"]
  end

  def test_computes_cache_hit_ratio
    stub = Class.new do
      def create(**params)
        {
          model: params[:model],
          stop_reason: "end_turn",
          usage: {
            input_tokens:                20,
            output_tokens:               10,
            cache_creation_input_tokens:  0,
            cache_read_input_tokens:     80,
          },
        }
      end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    stub.new.create(model: "claude-sonnet-4-6", max_tokens: 10, messages: [])
    span = @exporter.finished_spans.last

    # cache_read / (input + cache_read) = 80 / 100 = 0.8
    assert_equal 0.8, span.attributes["gen_ai.anthropic.cache_hit_ratio"]
  end

  def test_records_error_when_create_raises
    stub = Class.new do
      def create(**_); raise "api down"; end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    assert_raises(RuntimeError) { stub.new.create(model: "claude-opus-4-7", messages: []) }
    span = @exporter.finished_spans.last
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_response_with_only_some_keys_does_not_crash
    # Real Anthropic responses can omit `stop_reason` (streaming intermediate),
    # `usage` (failures), or `id` (some local mock backends). Each absence
    # must result in *no* attribute set, not an exception.
    stub = Class.new do
      def create(**params)
        # Returns a minimal Hash: model only.
        { model: params[:model] }
      end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    stub.new.create(model: "claude-sonnet-4-6", messages: [])
    span = @exporter.finished_spans.last

    assert_equal "claude-sonnet-4-6", span.attributes["gen_ai.response.model"]
    refute span.attributes.key?("gen_ai.response.id")
    refute span.attributes.key?("gen_ai.response.finish_reasons")
    refute span.attributes.key?("gen_ai.usage.input_tokens")
    refute span.attributes.key?("gen_ai.usage.cost_usd")
    refute span.attributes.key?("gen_ai.anthropic.cache_hit_ratio")
  end

  def test_partial_usage_keys_set_only_what_is_present
    # Some keys present, others missing — each present Integer maps to its
    # attribute, missing keys are silently skipped.
    stub = Class.new do
      def create(**params)
        { model: params[:model], usage: { input_tokens: 50 } }
      end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    stub.new.create(model: "claude-sonnet-4-6", messages: [])
    span = @exporter.finished_spans.last

    assert_equal 50, span.attributes["gen_ai.usage.input_tokens"]
    refute span.attributes.key?("gen_ai.usage.output_tokens")
    refute span.attributes.key?("gen_ai.anthropic.cache_creation_input_tokens")
    refute span.attributes.key?("gen_ai.anthropic.cache_read_input_tokens")
  end

  def test_usage_non_hash_is_ignored
    stub = Class.new do
      def create(**params)
        { model: params[:model], usage: "not a hash" }
      end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    stub.new.create(model: "claude-sonnet-4-6", messages: [])
    span = @exporter.finished_spans.last
    assert_equal "claude-sonnet-4-6", span.attributes["gen_ai.response.model"]
    refute span.attributes.key?("gen_ai.usage.input_tokens")
  end

  def test_instrument_is_idempotent_and_returns_target_class
    stub = Class.new do
      def create(**_); { model: "x" }; end
    end
    first  = Sashiko::Adapters::Anthropic.instrument!(stub)
    second = Sashiko::Adapters::Anthropic.instrument!(stub)
    assert_same stub, first,  "instrument! must return the class on first call"
    assert_same stub, second, "instrument! must return the class on subsequent calls (no nil)"
    # And only one Wrapper prepended (no double-emission).
    stub.new.create(model: "claude-sonnet-4-6")
    assert_equal 1, @exporter.finished_spans.length,
      "double-instrumentation must not produce duplicate spans"
  end

  def test_instrument_in_box_raises_box_not_enabled_error_outside_box_mode
    skip "test runs only when RUBY_BOX is unset" if defined?(Ruby::Box) && Ruby::Box.enabled?
    err = assert_raises(Sashiko::Box::NotEnabledError) do
      Sashiko::Adapters::Anthropic.instrument_in_box!(Object.new, "X")
    end
    assert_match(/RUBY_BOX=1/, err.message)
  end

  def test_instrument_with_explicit_tracer_routes_to_alternate_provider
    alt_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    alt_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    alt_provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(alt_exporter)
    )
    alt_tracer = alt_provider.tracer("alt")

    stub = Class.new do
      def create(**params); { model: params[:model] }; end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub, tracer: alt_tracer)
    stub.new.create(model: "claude-sonnet-4-6")

    assert_equal 1, alt_exporter.finished_spans.length,
      "spans must be routed through the explicit tracer:"
    assert_empty @exporter.finished_spans,
      "default tracer must not see spans routed through an explicit tracer"
  end

  def test_unknown_model_skips_cost_silently
    stub = Class.new do
      def create(**params)
        { model: params[:model], usage: { input_tokens: 1, output_tokens: 1 } }
      end
    end
    Sashiko::Adapters::Anthropic.instrument!(stub)

    stub.new.create(model: "claude-future-99-7", messages: [])
    span = @exporter.finished_spans.last
    refute span.attributes.key?("gen_ai.usage.cost_usd"),
      "unknown model must not produce a cost_usd attribute"
  end
end
