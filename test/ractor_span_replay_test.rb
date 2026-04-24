require_relative "test_helper"

# Module-level receivers are Ractor-shareable.
module ReplayWork
  def self.flat(n) = n * 2

  def self.with_nested(n)
    Sashiko::Ractor.span("phase.fetch",   attributes: { "phase" => "fetch"   }) { n }
    Sashiko::Ractor.span("phase.compute", attributes: { "phase" => "compute" }) { n * 2 }
    n * 3
  end

  def self.slow(_n) = sleep(0.05)
end

class RactorSpanReplayTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  # THE headline guarantee of the Ractor span replay feature:
  # Work that happens inside a Ractor ends up as spans in the SAME trace
  # as the main-thread code that launched it. This is currently impossible
  # with vanilla OpenTelemetry Ruby.
  def test_ractor_worker_spans_share_trace_with_main_caller
    parent_trace_id = nil
    Sashiko.tracer.in_span("main.batch") do |p|
      parent_trace_id = p.context.trace_id
      Sashiko::Ractor.parallel_map([1, 2, 3], via: ReplayWork.method(:flat))
    end

    worker_spans = @exporter.finished_spans.select { _1.name == "ReplayWork.flat" }
    assert_equal 3, worker_spans.length, "expected one worker span per input item"
    worker_spans.each do |s|
      assert_equal parent_trace_id, s.trace_id,
        "worker span must share the trace_id of its parent (currently impossible in vanilla OTel Ruby)"
    end
  end

  def test_ractor_worker_spans_are_children_of_calling_span
    parent_span_id = nil
    Sashiko.tracer.in_span("main.batch") do |p|
      parent_span_id = p.context.span_id
      Sashiko::Ractor.parallel_map([1, 2, 3], via: ReplayWork.method(:flat))
    end

    @exporter.finished_spans
      .select { _1.name == "ReplayWork.flat" }
      .each { |s| assert_equal parent_span_id, s.parent_span_id }
  end

  def test_nested_spans_emitted_inside_ractor_form_correct_subtree
    Sashiko.tracer.in_span("main.batch") do
      Sashiko::Ractor.parallel_map([10], via: ReplayWork.method(:with_nested))
    end

    spans  = @exporter.finished_spans
    root   = spans.find { _1.name == "ReplayWork.with_nested" }
    fetch  = spans.find { _1.name == "phase.fetch"   }
    compute = spans.find { _1.name == "phase.compute" }
    assert root && fetch && compute

    # Nested spans recorded inside the Ractor should reconstruct as direct
    # children of the root worker span, with correct attributes.
    assert_equal root.span_id, fetch.parent_span_id
    assert_equal root.span_id, compute.parent_span_id
    assert_equal "fetch",   fetch.attributes["phase"]
    assert_equal "compute", compute.attributes["phase"]
  end

  def test_replayed_span_durations_reflect_actual_work_inside_ractor
    # The worker sleeps for a known amount. The replayed span's duration
    # must match that (not the replay time in the main thread).
    Sashiko::Ractor.parallel_map([1], via: ReplayWork.method(:slow))
    s = @exporter.finished_spans.find { _1.name == "ReplayWork.slow" }
    assert s
    duration_ms = (s.end_timestamp - s.start_timestamp) / 1_000_000.0
    assert_in_delta 50, duration_ms, 30,
      "replayed span duration must match actual work inside the Ractor (got #{duration_ms}ms)"
  end

  def test_attributes_on_root_worker_span_include_item_index
    Sashiko::Ractor.parallel_map([100, 200, 300], via: ReplayWork.method(:flat))
    indices = @exporter.finished_spans
      .select { _1.name == "ReplayWork.flat" }
      .map    { _1.attributes["item.index"] }
      .sort
    assert_equal [0, 1, 2], indices
  end

end
