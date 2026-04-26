# frozen_string_literal: true

# Bench: Sashiko::Ractor::Sink.replay throughput. Measures the
# main-side cost of replaying N pre-recorded SpanEvents as real OTel
# spans, isolated from the Ractor execution itself.
#
# Run:  bundle exec ruby bench/sink_replay_cost.rb

require_relative "_setup"

# Build a synthetic event batch: 1 root + N children.
def build_events(n)
  base = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
  root = Sashiko::Ractor::SpanEvent.new(
    id: 1, parent_id: nil, name: "root", kind: :internal,
    attributes: { "n" => n }.freeze,
    start_ns: base, end_ns: base + 1_000_000, status_error: nil,
  )
  children = (2..(n + 1)).map do |id|
    Sashiko::Ractor::SpanEvent.new(
      id:, parent_id: 1, name: "child", kind: :internal,
      attributes: { "i" => id - 1 }.freeze,
      start_ns: base + (id * 100), end_ns: base + (id * 100) + 500,
      status_error: nil,
    )
  end
  [root, *children].freeze
end

require "benchmark"

[10, 100, 1_000].each do |n|
  events = build_events(n)
  iterations = 1_000

  t = Benchmark.realtime do
    iterations.times do
      Sashiko::Ractor::Sink.replay(events, parent_carrier: {}, tracer: BenchSetup.tracer)
      BenchSetup.drain
    end
  end

  total_events = (n + 1) * iterations
  puts format("  %4d events × %4d iter = %d total events  →  %.3f s  (%.2f µs/event)",
              n + 1, iterations, total_events, t, t * 1_000_000 / total_events)
end
