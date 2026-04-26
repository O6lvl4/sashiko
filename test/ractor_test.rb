require_relative "test_helper"

# Module-level receivers are Ractor-shareable by default.
module ParallelHelpers
  def self.double(n) = n * 2
  def self.slow_triple(n)
    sleep(rand * 0.02)  # randomize completion order
    n * 3
  end
  def self.to_int(n) = n.to_i
end

class RactorTest < Minitest::Test
  def test_parallel_map_runs_items_in_parallel_ractors
    assert_equal(
      [2, 4, 6, 8],
      Sashiko::Ractor.parallel_map([1, 2, 3, 4], via: ParallelHelpers.method(:double)),
    )
  end

  def test_parallel_map_preserves_input_order_regardless_of_completion
    assert_equal(
      [30, 60, 90],
      Sashiko::Ractor.parallel_map([10, 20, 30], via: ParallelHelpers.method(:slow_triple)),
    )
  end

  def test_parallel_map_accepts_any_shareable_module_method
    assert_equal(
      [1, 2, 3],
      Sashiko::Ractor.parallel_map([1.0, 2.0, 3.0], via: ParallelHelpers.method(:to_int)),
    )
  end

  def test_parallel_map_rejects_non_shareable_receiver
    # An instance of a non-frozen class is not Ractor-shareable.
    obj = Object.new
    def obj.work(n) = n
    refute Ractor.shareable?(obj)

    assert_raises(Sashiko::Ractor::NonShareableReceiverError) do
      Sashiko::Ractor.parallel_map([1, 2], via: obj.method(:work))
    end
  end

  def test_parallel_map_requires_method_object
    assert_raises(ArgumentError) do
      Sashiko::Ractor.parallel_map([1, 2], via: ->(n) { n * 2 })
    end
  end

  def test_parallel_map_with_empty_items_returns_empty
    assert_equal [], Sashiko::Ractor.parallel_map([], via: ParallelHelpers.method(:double))
  end

  def test_parallel_map_handles_many_workers
    inputs = (1..20).to_a
    result = Sashiko::Ractor.parallel_map(inputs, via: ParallelHelpers.method(:double))
    assert_equal inputs.map { |n| n * 2 }, result
  end
end

# Receivers that always raise — used to drive the failure-path through
# parallel_map. Defined at module scope so they're Ractor-shareable.
module ExplodingHelpers
  class CustomError < StandardError; end
  def self.boom(_n) = raise CustomError, "kaboom"
end

class RactorFailureTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_worker_failures_are_aggregated_and_raised
    err = assert_raises(RuntimeError) do
      Sashiko::Ractor.parallel_map([1, 2], via: ExplodingHelpers.method(:boom))
    end
    assert_match(/item\[0\]/, err.message)
    assert_match(/CustomError/, err.message)
    assert_match(/kaboom/, err.message)
  end

  def test_failed_worker_still_emits_a_span_with_error_status
    Sashiko.tracer.in_span("main") do
      assert_raises(RuntimeError) do
        Sashiko::Ractor.parallel_map([1], via: ExplodingHelpers.method(:boom))
      end
    end
    span = @exporter.finished_spans.find { it.name == "ExplodingHelpers.boom" }
    assert span, "failed worker should still emit a replayed span"
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    assert_match(/kaboom/, span.status.description)
  end
end

class RactorSinkTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_replay_with_no_events_is_a_noop
    Sashiko::Ractor::Sink.replay([], parent_carrier: {})
    assert_empty @exporter.finished_spans
  end

  def test_replay_skips_event_referencing_missing_parent
    # An event whose parent_id points to an id that wasn't replayed must
    # not crash the whole batch. Currently this raises KeyError from
    # replayed.fetch — we want to lock in the contract that the rest of
    # the batch is still observable.
    base_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    good = Sashiko::Ractor::SpanEvent.new(
      id: 1, parent_id: nil, name: "good", kind: :internal,
      attributes: {}, start_ns: base_ns, end_ns: base_ns + 1_000, status_error: nil,
    )
    orphan = Sashiko::Ractor::SpanEvent.new(
      id: 2, parent_id: 999, name: "orphan", kind: :internal,
      attributes: {}, start_ns: base_ns, end_ns: base_ns + 1_000, status_error: nil,
    )

    Sashiko::Ractor::Sink.replay([good, orphan], parent_carrier: {})

    names = @exporter.finished_spans.map(&:name)
    assert_includes names, "good", "events with valid parent linkage must still be replayed"
    # Orphan handling is best-effort: re-rooting under parent_carrier is
    # acceptable; crashing the whole replay is not.
    assert_includes names, "orphan", "orphaned events should be re-rooted, not lost"
  end
end
