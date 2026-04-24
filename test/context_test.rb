require_relative "test_helper"

class ContextTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  # The headline guarantee: a span started inside Sashiko::Context.thread
  # has the outer span as its parent, not root.
  def test_thread_preserves_parent_span
    tracer = Sashiko.tracer
    child_span = nil
    parent_span_id = nil

    tracer.in_span("outer") do |outer|
      parent_span_id = outer.context.span_id
      Sashiko::Context.thread do
        tracer.in_span("inner") do |inner|
          child_span = inner
        end
      end.join
    end

    assert_equal parent_span_id, child_span.parent_span_id,
      "inner span should be a child of outer, not a root"
  end

  def test_parallel_map_preserves_parent_for_every_worker
    tracer = Sashiko.tracer
    parent_id = nil

    tracer.in_span("parent") do |p|
      parent_id = p.context.span_id
      Sashiko::Context.parallel_map([1, 2, 3]) do |_|
        tracer.in_span("worker") { }
      end
    end

    workers = @exporter.finished_spans.select { |s| s.name == "worker" }
    assert_equal 3, workers.length
    workers.each do |w|
      assert_equal parent_id, w.parent_span_id,
        "every worker span should be a child of `parent`"
    end
  end

  # Contrast test: WITHOUT Sashiko::Context.thread, a naive Thread.new
  # produces a root-level inner span. Documents exactly what sashiko solves.
  def test_naive_thread_loses_parent
    tracer = Sashiko.tracer
    child_span = nil

    tracer.in_span("outer") do
      Thread.new do
        tracer.in_span("inner") { |s| child_span = s }
      end.join
    end

    expected_root = ("\x00" * 8).b
    assert_equal expected_root, child_span.parent_span_id,
      "plain Thread.new should lose OTel context (this is the bug sashiko fixes)"
  end

  def test_parallel_map_returns_results_in_input_order
    tracer = Sashiko.tracer
    results = nil
    tracer.in_span("p") do
      results = Sashiko::Context.parallel_map([10, 20, 30]) do |n|
        sleep(rand * 0.01)  # randomize completion order
        n * 2
      end
    end
    assert_equal [20, 40, 60], results
  end
end
