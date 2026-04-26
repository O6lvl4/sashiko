# frozen_string_literal: true

require_relative "test_helper"
require "active_support/notifications"
require "active_job"
require "sashiko/rails"

# In-process backend for ActiveJob: enqueued jobs are simply remembered;
# we drive them via .perform_now-equivalent logic ourselves so the test
# observes both serialize and deserialize paths.
ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(IO::NULL)

class RailsAsyncTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_async_runs_in_thread_under_parent_span
    parent_id = nil
    Sashiko.tracer.in_span("request") do |s|
      parent_id = s.context.span_id
      Sashiko::Rails.async("orders.fetch") do
        sleep 0.001
      end.join
    end

    span = @exporter.finished_spans.find { |x| x.name == "orders.fetch" }
    assert span, "async block must emit a span"
    assert_equal parent_id, span.parent_span_id,
      "async span must be a child of the surrounding request span"
  end

  def test_async_with_explicit_tracer_routes_to_alt_provider
    alt_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    alt_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    alt_provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(alt_exporter)
    )
    alt_tracer = alt_provider.tracer("alt")

    Sashiko::Rails.async("alt.work", tracer: alt_tracer) {}.join
    assert_equal ["alt.work"], alt_exporter.finished_spans.map(&:name)
    assert_empty @exporter.finished_spans.select { |s| s.name == "alt.work" }
  end
end

class RailsNotificationsBridgeTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_bridge_notifications_emits_one_span_per_event
    Sashiko::Rails.bridge_notifications(/^bridge_test\./)

    ActiveSupport::Notifications.instrument("bridge_test.lookup", id: 42, kind: "user") {}
    ActiveSupport::Notifications.instrument("bridge_test.compute", duration_ms: 5) {}
    ActiveSupport::Notifications.instrument("ignore_me", x: 1) {}  # different prefix

    names = @exporter.finished_spans.map(&:name)
    assert_includes names, "bridge_test.lookup"
    assert_includes names, "bridge_test.compute"
    refute_includes names, "ignore_me"

    lookup = @exporter.finished_spans.find { |s| s.name == "bridge_test.lookup" }
    assert_equal 42, lookup.attributes["id"]
    assert_equal "user", lookup.attributes["kind"]
  end
end

class GreeterJob < ActiveJob::Base
  include Sashiko::Rails::TracedJob

  cattr_accessor :captured_carrier
  cattr_accessor :captured_trace_id

  def perform(name)
    self.class.captured_carrier  = Sashiko::Context.carrier.to_h
    self.class.captured_trace_id = OpenTelemetry::Trace.current_span.context.trace_id
  end
end

class RailsTracedJobTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
    GreeterJob.captured_carrier  = nil
    GreeterJob.captured_trace_id = nil
  end

  def test_serialize_includes_carrier_when_in_a_span
    captured = nil
    Sashiko.tracer.in_span("enqueue.context") do
      job = GreeterJob.new("alice")
      data = job.serialize
      captured = data[Sashiko::Rails::TracedJob::CARRIER_KEY]
    end
    assert captured, "serialized job must carry a Sashiko trace carrier"
    assert captured.key?("traceparent"), "carrier should include W3C traceparent"
  end

  def test_perform_attaches_carrier_and_inherits_trace
    parent_trace_id = nil
    serialized = nil

    Sashiko.tracer.in_span("enqueue") do |s|
      parent_trace_id = s.context.trace_id
      serialized = GreeterJob.new("alice").serialize
    end

    # Simulate worker pickup: deserialize + perform.
    job = ActiveJob::Base.deserialize(serialized)
    job.perform_now

    inside_carrier = GreeterJob.captured_carrier
    inside_trace_id = GreeterJob.captured_trace_id
    assert inside_carrier, "perform-side context must be set"
    refute_equal "\x00".b * 16, inside_trace_id,
      "trace_id inside perform must not be all-zero"
    # The perform-side trace_id must match the enqueue-side parent.
    parent_traceparent = serialized[Sashiko::Rails::TracedJob::CARRIER_KEY]["traceparent"]
    parent_tid_hex = parent_traceparent.split("-")[1]
    assert_equal parent_tid_hex, inside_trace_id.unpack1("H*"),
      "perform trace_id must inherit from enqueue's traceparent"
  end

  def test_perform_without_carrier_does_not_crash
    # Outside any span: carrier hash is empty.
    serialized = GreeterJob.new("solo").serialize
    job = ActiveJob::Base.deserialize(serialized)
    job.perform_now
    refute_nil GreeterJob.captured_carrier
  end
end

class RailsInstallTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def test_install_with_notifications_pattern_subscribes
    Sashiko::Rails.install!(notifications: /^install_test\./)
    ActiveSupport::Notifications.instrument("install_test.hit", value: 1) {}
    names = @exporter.finished_spans.map(&:name)
    assert_includes names, "install_test.hit"
  end

  def test_install_with_no_args_is_a_noop
    assert_equal true, Sashiko::Rails.install!
  end
end
