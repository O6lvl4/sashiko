# frozen_string_literal: true

# Talk demo 03 — Thread stitched: same code as demo 02, but using
# Sashiko::Context.parallel_map to preserve the OpenTelemetry context
# across the Thread boundary. The 3 worker spans become children of
# the request, exactly as expected.
#
# Run:  bundle exec ruby examples/talk/03_thread_stitched.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sashiko"
require_relative "_tree"

exporter = TalkDemo.setup_otel
tracer   = OpenTelemetry.tracer_provider.tracer("stitched")

tracer.in_span("request") do
  Sashiko::Context.parallel_map([0, 1, 2]) do |i|
    tracer.in_span("worker_#{i}") { sleep 0.001 }
  end
end

TalkDemo.print_tree("03 — Sashiko::Context.parallel_map (stitched):", exporter)
