# frozen_string_literal: true

# Bench: per-call overhead of Sashiko::Traced vs raw `tracer.in_span`.
#
# Both produce the same span shape; the question is what the DSL costs
# on top of the OTel SDK call.
#
# Run:  bundle exec ruby bench/traced_overhead.rb

require_relative "_setup"

class RawSpan
  TRACER = BenchSetup.tracer
  def call(x) = TRACER.in_span("RawSpan#call", attributes: { "code.function" => "call", "code.namespace" => "RawSpan" }) { x * 2 }
end

class TracedSpan
  extend Sashiko::Traced
  trace :call
  def call(x) = x * 2
end

class TracedWithProc
  extend Sashiko::Traced
  trace :call, attributes: ->(x) { { "x" => x } }
  def call(x) = x * 2
end

raw     = RawSpan.new
traced  = TracedSpan.new
proc_at = TracedWithProc.new

# Sanity check: all three emit a span.
[raw, traced, proc_at].each { |o| o.call(1) }
raise "no spans" if BenchSetup::EXPORTER.finished_spans.empty?
BenchSetup.drain

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("tracer.in_span (raw)")          { raw.call(1);     BenchSetup.drain if rand < 0.001 }
  x.report("Sashiko::Traced (static attrs)") { traced.call(1);  BenchSetup.drain if rand < 0.001 }
  x.report("Sashiko::Traced + Proc attrs")   { proc_at.call(1); BenchSetup.drain if rand < 0.001 }
  x.compare!
end
