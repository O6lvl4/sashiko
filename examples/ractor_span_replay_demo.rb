$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "sashiko"

# Tree-printer exporter: shows the unified trace as Jaeger would display it.
class TreeExporter
  def initialize; @spans = []; end
  def export(spans, _timeout: nil)
    @spans.concat(spans)
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end
  def force_flush(timeout: nil); OpenTelemetry::SDK::Trace::Export::SUCCESS; end
  def shutdown(timeout: nil);    OpenTelemetry::SDK::Trace::Export::SUCCESS; end

  def dump
    by_parent = @spans.group_by { it.parent_span_id.unpack1("H*") }
    root_spans = @spans.select { it.parent_span_id.unpack1("H*") == ("0" * 16) }
    root_spans.each { |r| print_tree(r, by_parent, 0) }
  end

  private

  def print_tree(span, by_parent, depth)
    pad = "  " * depth
    dur_ms = ((span.end_timestamp - span.start_timestamp) / 1_000_000.0).round(1)
    idx = span.attributes["item.index"]
    tag = idx ? " [item.index=#{idx}]" : ""
    puts "#{pad}├─ #{span.name} (#{dur_ms}ms)#{tag}"
    (by_parent[span.span_id.unpack1("H*")] || []).each { |c| print_tree(c, by_parent, depth + 1) }
  end
end

exporter = TreeExporter.new
OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
  )
end

# User code: a CPU-bound pipeline expressed on a Ractor-shareable module.
# Inside each Ractor, phases are wrapped with Sashiko::Ractor.span(...),
# producing SpanEvents that ride back to the main Ractor via Ractor::Port.
module PrimePipeline
  def self.run(upper_bound)
    candidates = Sashiko::Ractor.span("enumerate", attributes: { "range.upper" => upper_bound }) do
      (2..upper_bound).to_a
    end

    primes = Sashiko::Ractor.span("sieve") do
      candidates.select { |i| (2..Math.sqrt(i)).none? { |d| i % d == 0 } }
    end

    Sashiko::Ractor.span("summarize", attributes: { "prime.count" => primes.length }) do
      primes.last
    end
  end
end

Sashiko.tracer.in_span("main.batch", attributes: { "workers" => 3 }) do
  results = Sashiko::Ractor.parallel_map(
    [5_000, 10_000, 15_000],
    via: PrimePipeline.method(:run),
  )
  puts
  puts "Largest prime below each N: #{results.inspect}"
  puts
end

puts "━" * 70
puts " Trace tree"
puts "━" * 70
exporter.dump
