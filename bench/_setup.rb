# frozen_string_literal: true

# Shared OTel setup for benchmark scripts. Uses an in-memory exporter
# with a SimpleSpanProcessor so emit overhead is visible (no batching
# hides the cost). Drains the exporter between IPS warmups to avoid
# unbounded memory growth.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "sashiko"
require "benchmark/ips"

module BenchSetup
  EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  OpenTelemetry::SDK.configure do |c|
    c.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(EXPORTER)
    )
  end

  def self.tracer = OpenTelemetry.tracer_provider.tracer("bench")
  def self.drain  = EXPORTER.reset
end
