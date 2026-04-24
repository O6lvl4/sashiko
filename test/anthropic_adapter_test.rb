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
end
