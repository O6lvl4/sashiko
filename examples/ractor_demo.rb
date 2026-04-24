$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "sashiko"

# Minimal span printer
class LineExporter
  def export(spans, _timeout: nil)
    spans.each do |s|
      attrs = s.attributes.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      duration_ms = ((s.end_timestamp - s.start_timestamp) / 1_000_000.0).round(2)
      puts "[#{duration_ms.to_s.rjust(6)}ms] #{s.name}  #{attrs}"
    end
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end
  def force_flush(timeout: nil); OpenTelemetry::SDK::Trace::Export::SUCCESS; end
  def shutdown(timeout: nil);    OpenTelemetry::SDK::Trace::Export::SUCCESS; end
end
OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(LineExporter.new))
end

# CPU-bound work that benefits from true parallelism (separate cores, no GVL).
# Must be defined on a Ractor-shareable receiver (a Module here).
module Crunch
  def self.primes_below(n)
    (2...n).select do |i|
      (2..Math.sqrt(i)).none? { |d| i % d == 0 }
    end.last
  end
end

Sashiko.tracer.in_span("batch") do |span|
  span.set_attribute("workload", "prime-search")
  results = Sashiko::Ractor.parallel_map(
    [50_000, 60_000, 70_000, 80_000],
    via: Crunch.method(:primes_below),
  )
  puts "largest primes below each N: #{results.inspect}"
end
