require_relative "test_helper"
require "faraday"
require "sashiko/adapters/faraday"

class FaradayAdapterTest < Minitest::Test
  def setup
    @exporter = TestHelper.exporter
    @exporter.reset
  end

  def build_conn(stubs)
    ::Faraday.new("https://api.example.com") do |f|
      f.use Sashiko::Adapters::Faraday::Middleware
      f.adapter :test, stubs
    end
  end

  def test_emits_client_span_with_required_http_attributes
    stubs = ::Faraday::Adapter::Test::Stubs.new do |s|
      s.get("/widgets/42") { [200, {}, "ok"] }
    end
    build_conn(stubs).get("/widgets/42")

    span = @exporter.finished_spans.last
    assert_equal "GET", span.name
    assert_equal :client, span.kind
    assert_equal "GET", span.attributes["http.request.method"]
    assert_equal "https://api.example.com/widgets/42", span.attributes["url.full"]
    assert_equal "api.example.com", span.attributes["server.address"]
    assert_equal 443, span.attributes["server.port"]
    assert_equal 200, span.attributes["http.response.status_code"]
    refute span.attributes.key?("error.type"), "successful response must not set error.type"
    refute_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_marks_span_errored_on_4xx_and_sets_error_type
    stubs = ::Faraday::Adapter::Test::Stubs.new do |s|
      s.get("/missing") { [404, {}, ""] }
    end
    build_conn(stubs).get("/missing")

    span = @exporter.finished_spans.last
    assert_equal 404, span.attributes["http.response.status_code"]
    assert_equal "404", span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_marks_span_errored_on_5xx_and_sets_error_type
    stubs = ::Faraday::Adapter::Test::Stubs.new do |s|
      s.get("/oops") { [503, {}, ""] }
    end
    build_conn(stubs).get("/oops")

    span = @exporter.finished_spans.last
    assert_equal 503, span.attributes["http.response.status_code"]
    assert_equal "503", span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_explicit_tracer_kwarg_routes_to_alternate_provider
    alt_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    alt_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    alt_provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(alt_exporter)
    )
    alt_tracer = alt_provider.tracer("alt")

    stubs = ::Faraday::Adapter::Test::Stubs.new do |s|
      s.get("/ok") { [200, {}, "ok"] }
    end
    conn = ::Faraday.new("https://api.example.com") do |f|
      f.use Sashiko::Adapters::Faraday::Middleware, tracer: alt_tracer
      f.adapter :test, stubs
    end
    conn.get("/ok")

    assert_equal ["GET"], alt_exporter.finished_spans.map(&:name)
    assert_empty @exporter.finished_spans.select { |s| s.name == "GET" },
      "default tracer must not see spans routed through an explicit tracer"
  end

  def test_records_exception_when_underlying_call_raises
    stubs = ::Faraday::Adapter::Test::Stubs.new do |s|
      s.get("/boom") { raise ::Faraday::ConnectionFailed, "down" }
    end

    assert_raises(::Faraday::ConnectionFailed) { build_conn(stubs).get("/boom") }

    span = @exporter.finished_spans.last
    assert_equal "Faraday::ConnectionFailed", span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    refute_empty span.events
    assert_equal "exception", span.events.first.name
  end
end
