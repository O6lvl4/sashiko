require_relative "test_helper"

class TracedTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_wraps_method_and_emits_span
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Widget"; end
      trace :ping
      def ping; 42; end
    end

    assert_equal 42, klass.new.ping
    span = @exporter.finished_spans.last
    assert_equal "Widget#ping", span.name
    assert_equal "ping",   span.attributes["code.function"]
    assert_equal "Widget", span.attributes["code.namespace"]
    refute_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_records_exception_and_sets_error_status
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Boom"; end
      trace :explode
      def explode; raise "oops"; end
    end

    assert_raises(RuntimeError) { klass.new.explode }
    span = @exporter.finished_spans.last
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    refute_empty span.events
    assert_equal "exception", span.events.first.name
  end

  def test_attributes_proc_receives_args
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Greeter"; end
      trace :greet, attributes: ->(name) { { "user.name" => name } }
      def greet(name); "hi #{name}"; end
    end

    klass.new.greet("motodera")
    span = @exporter.finished_spans.last
    assert_equal "motodera", span.attributes["user.name"]
  end

  def test_nested_calls_form_parent_child_spans
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Outer"; end
      trace :outer
      trace :inner
      def outer; inner; end
      def inner; "done"; end
    end

    klass.new.outer
    spans = @exporter.finished_spans
    inner = spans.find { |s| s.name == "Outer#inner" }
    outer = spans.find { |s| s.name == "Outer#outer" }
    assert inner && outer
    assert_equal outer.span_id, inner.parent_span_id
  end

  def test_trace_all_matches_by_regex
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Handlers"; end
      def handle_create; :c; end
      def handle_update; :u; end
      def private_helper; :h; end
      trace_all matching: /^handle_/
    end

    instance = klass.new
    instance.handle_create
    instance.handle_update
    instance.private_helper

    names = @exporter.finished_spans.map(&:name)
    assert_includes names, "Handlers#handle_create"
    assert_includes names, "Handlers#handle_update"
    refute_includes names, "Handlers#private_helper",
      "trace_all should only match methods whose name matches the pattern"
  end

  def test_trace_all_skips_methods_already_traced_directly
    # A method explicitly traced by `trace :foo, attributes: ...` should
    # NOT be re-overlaid by a subsequent trace_all — that would clobber
    # the per-method options and double the span emission.
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Mixed"; end
      def handle_a; :a; end
      def handle_b; :b; end
      trace :handle_a, attributes: ->(*) { { "explicit" => "yes" } }
      trace_all matching: /^handle_/
    end

    klass.new.handle_a
    spans = @exporter.finished_spans.select { |s| s.name == "Mixed#handle_a" }
    assert_equal 1, spans.length, "handle_a should produce exactly one span"
    assert_equal "yes", spans.first.attributes["explicit"],
      "trace_all must not overwrite the explicit `trace` definition"
  end

  def test_record_args_and_attributes_proc_combine
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Combo"; end
      trace :work, record_args: true, attributes: ->(x, y:) { { "x" => x, "y" => y } }
      def work(x, y:); x + y; end
    end

    klass.new.work(1, y: 2)
    span = @exporter.finished_spans.last
    assert_equal 1, span.attributes["x"]
    assert_equal 2, span.attributes["y"]
    assert_equal 2, span.attributes["code.args.count"],
      "record_args should count both positional and keyword args"
  end

  def test_explicit_tracer_kwarg_overrides_default
    # Build a second tracer_provider + exporter pair and verify spans
    # routed through it never touch the default test_helper exporter.
    alt_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    alt_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    alt_provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(alt_exporter)
    )
    alt_tracer = alt_provider.tracer("alt")

    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Routed"; end
      trace :work, tracer: alt_tracer
      def work; 1; end
    end

    klass.new.work
    assert_equal ["Routed#work"], alt_exporter.finished_spans.map(&:name),
      "spans must be routed through the explicit tracer:"
    assert_empty @exporter.finished_spans.select { |s| s.name == "Routed#work" },
      "default tracer must not see spans tagged with an explicit tracer:"
  end

  def test_attributes_static_hash_is_attached
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Static"; end
      trace :ping, attributes: { "service.kind" => "internal" }
      def ping; :ok; end
    end

    klass.new.ping
    span = @exporter.finished_spans.last
    assert_equal "internal", span.attributes["service.kind"]
  end
end
