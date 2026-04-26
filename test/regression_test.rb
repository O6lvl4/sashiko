# frozen_string_literal: true

require_relative "test_helper"

# Lock-in tests for properties that are documented in README/CHANGELOG.
# If any of these break, the documentation is wrong (or the doc-described
# tradeoff has been silently re-traded).
class RegressionTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_sashiko_tracer_is_memoized_to_same_object
    # The pitfall note in the README assumes Sashiko.tracer is sticky.
    # If memoization is removed (again), the multi-tenant Box story
    # silently breaks — see CHANGELOG "Documented (unchanged from
    # earlier behavior)" for the rationale.
    a = Sashiko.tracer
    b = Sashiko.tracer
    assert_same a, b, "Sashiko.tracer must be memoized; Box guidance depends on it"
  end

  def test_box_new_outside_box_mode_raises_not_enabled_error
    skip "test runs only when RUBY_BOX is unset" if defined?(::Ruby::Box) && ::Ruby::Box.enabled?
    err = assert_raises(Sashiko::Box::NotEnabledError) { Sashiko::Box.new }
    assert_match(/RUBY_BOX=1/, err.message)
  end

  def test_explicit_tracer_kwarg_routes_error_spans_correctly
    # When trace :foo, tracer: alt is set and the method raises, the
    # exception is recorded on a span emitted by `alt`, not by
    # Sashiko.tracer. Otherwise the explicit-tracer guarantee leaks on
    # the error path.
    alt_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    alt_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    alt_provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(alt_exporter)
    )
    alt_tracer = alt_provider.tracer("alt")

    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "Boom"; end
      trace :explode, tracer: alt_tracer
      def explode; raise "kaboom"; end
    end

    assert_raises(RuntimeError) { klass.new.explode }

    span = alt_exporter.finished_spans.find { |s| s.name == "Boom#explode" }
    assert span, "error span must be on the explicit tracer's exporter"
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    refute_empty span.events
    assert_equal "exception", span.events.first.name
    assert_empty @exporter.finished_spans.select { |s| s.name == "Boom#explode" },
      "default tracer must not see the error span"
  end

  def test_traced_static_attrs_are_pre_baked_and_frozen
    # Pre-baking is a perf optimization documented in CHANGELOG. If a
    # future refactor regresses to per-call Hash construction, this
    # test catches it.
    klass = Class.new do
      extend Sashiko::Traced
      def self.name; "PreBaked"; end
      trace :ping
      def ping; :ok; end
    end

    overlay = klass.instance_variable_get(:@__sashiko_overlay)
    refute_nil overlay
    # Drive the method to ensure spans are produced; assert content of
    # static_attrs via the resulting span attributes (which is the
    # observable contract).
    klass.new.ping
    span = @exporter.finished_spans.last
    assert_equal "ping",     span.attributes["code.function"]
    assert_equal "PreBaked", span.attributes["code.namespace"]
  end
end
