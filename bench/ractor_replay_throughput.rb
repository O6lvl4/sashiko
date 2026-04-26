# frozen_string_literal: true

# Bench: Sashiko::Ractor.parallel_map throughput vs sequential
# execution. The work is intentionally CPU-bound (prime sieve over
# small ranges) so multi-core wins are observable.
#
# Run:  bundle exec ruby bench/ractor_replay_throughput.rb

require_relative "_setup"

module Sieve
  def self.run(upper)
    Sashiko::Ractor.span("sieve", attributes: { "upper" => upper }) do
      (2..upper).select { |i| (2..Math.sqrt(i)).none? { |d| (i % d).zero? } }.length
    end
  end
end

# Sequential variant for comparison.
def sequential_run(items)
  BenchSetup.tracer.in_span("seq.batch") do
    items.map do |upper|
      BenchSetup.tracer.in_span("sieve", attributes: { "upper" => upper }) do
        (2..upper).select { |i| (2..Math.sqrt(i)).none? { |d| (i % d).zero? } }.length
      end
    end
  end
end

ITEMS = [3_000, 5_000, 7_000, 9_000, 11_000, 13_000, 15_000, 17_000]

# Warm up + sanity.
sequential_run(ITEMS)
BenchSetup.drain
Sashiko.tracer.in_span("warm") do
  Sashiko::Ractor.parallel_map(ITEMS, via: Sieve.method(:run))
end
BenchSetup.drain

require "benchmark"

n = 5
seq_t = Benchmark.realtime { n.times { sequential_run(ITEMS); BenchSetup.drain } }
par_t = Benchmark.realtime do
  n.times do
    Sashiko.tracer.in_span("par.batch") do
      Sashiko::Ractor.parallel_map(ITEMS, via: Sieve.method(:run))
    end
    BenchSetup.drain
  end
end

puts "Items per batch: #{ITEMS.length} (#{ITEMS.inspect})"
puts "Iterations:      #{n}"
puts
puts format("  sequential:                %7.3f s  (%5.1f ms/batch)", seq_t, seq_t * 1_000 / n)
puts format("  Sashiko::Ractor.parallel:  %7.3f s  (%5.1f ms/batch)", par_t, par_t * 1_000 / n)
puts format("  speedup:                   %5.2fx", seq_t / par_t)
puts
puts "(Speedup is bounded by core count and Ractor::Port overhead;"
puts " 2-4x is typical on a 4-core machine for this workload.)"
