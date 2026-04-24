require_relative "test_helper"

class CarrierTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_carrier_is_a_plain_hash_of_w3c_headers
    tracer = Sashiko.tracer
    tracer.in_span("outer") do
      carrier = Sashiko::Context.carrier
      assert_kind_of Hash, carrier
      assert carrier.key?("traceparent"),
        "carrier should include W3C traceparent header"
      assert_match(/^00-[0-9a-f]{32}-[0-9a-f]{16}-\d{2}$/, carrier["traceparent"])
    end
  end

  def test_attach_makes_captured_span_the_parent
    tracer = Sashiko.tracer
    captured_carrier = nil
    parent_trace_id = nil
    parent_span_id = nil

    tracer.in_span("producer") do |p|
      captured_carrier = Sashiko::Context.carrier
      parent_trace_id  = p.context.trace_id
      parent_span_id   = p.context.span_id
    end

    # Simulate "dequeue on the other side" — producer span has already ended.
    Sashiko::Context.attach(captured_carrier) do
      tracer.in_span("worker") { }
    end

    worker = @exporter.finished_spans.find { |s| s.name == "worker" }
    assert_equal parent_trace_id, worker.trace_id,
      "worker must share trace_id with producer"
    assert_equal parent_span_id, worker.parent_span_id,
      "worker must list producer as its parent"
  end

  def test_carrier_survives_serialization_roundtrip
    tracer = Sashiko.tracer
    json_blob = nil
    original_trace_id = nil

    tracer.in_span("producer") do |p|
      json_blob = Sashiko::Context.carrier.to_json
      original_trace_id = p.context.trace_id
    end

    # Emulate crossing a queue / network: only the JSON blob survives.
    rehydrated = JSON.parse(json_blob)
    Sashiko::Context.attach(rehydrated) do
      tracer.in_span("worker") { }
    end

    worker = @exporter.finished_spans.find { |s| s.name == "worker" }
    assert_equal original_trace_id, worker.trace_id
  end

  def test_empty_carrier_yields_fresh_root_trace
    tracer = Sashiko.tracer
    Sashiko::Context.attach({}) do
      tracer.in_span("standalone") { }
    end
    s = @exporter.finished_spans.find { |sp| sp.name == "standalone" }
    expected_root = ("\x00" * 8).b
    assert_equal expected_root, s.parent_span_id,
      "an empty carrier should produce a fresh root span, not crash"
  end
end
