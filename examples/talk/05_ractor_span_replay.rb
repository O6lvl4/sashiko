# frozen_string_literal: true

# Talk demo 05 — Sashiko's Ractor span replay. Each Ractor records
# work as plain `Sashiko::Ractor::SpanEvent` data (frozen, no OTel
# dependency), ships it back via `Ractor::Port`, and the main side
# replays each event as a real OTel span with original timing and
# parent linkage. The trace tree below was built from work that
# happened on separate cores.
#
# Run:  bundle exec ruby examples/talk/05_ractor_span_replay.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sashiko"
require_relative "_tree"

exporter = TalkDemo.setup_otel

# Module-level receiver: Ractor-shareable by default.
module Pipeline
  def self.run(n)
    Sashiko::Ractor.span("enumerate") { (2..n).to_a }
    Sashiko::Ractor.span("sieve")     { (2..n).select { |i| (2..Math.sqrt(i)).none? { |d| i % d == 0 } } }
    Sashiko::Ractor.span("summarize") { :done }
  end
end

Sashiko.tracer.in_span("main.batch") do
  Sashiko::Ractor.parallel_map([1_000, 2_000, 3_000], via: Pipeline.method(:run))
end

TalkDemo.print_tree("05 — Ractor span replay (work ran on separate cores):", exporter)
