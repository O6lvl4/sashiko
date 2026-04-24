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
end
