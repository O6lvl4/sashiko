# frozen_string_literal: true

# Talk demo 01 — Baseline: vanilla OpenTelemetry without any boundary
# crossing. This is the case OTel handles correctly. We use it later
# as the "expected shape" to compare against.
#
# Run:  bundle exec ruby examples/talk/01_baseline.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sashiko"
require_relative "_tree"

exporter = TalkDemo.setup_otel
tracer   = OpenTelemetry.tracer_provider.tracer("baseline")

tracer.in_span("request") do
  3.times do |i|
    tracer.in_span("worker_#{i}") { sleep 0.001 }
  end
end

TalkDemo.print_tree("01 — baseline (sequential, no boundary):", exporter)
