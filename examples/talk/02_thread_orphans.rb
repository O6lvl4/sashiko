# frozen_string_literal: true

# Talk demo 02 — Thread orphans: vanilla `Thread.new` drops the
# OpenTelemetry context. Each thread starts a new root span,
# disconnected from the request that spawned it.
#
# Run:  bundle exec ruby examples/talk/02_thread_orphans.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sashiko"
require_relative "_tree"

exporter = TalkDemo.setup_otel
tracer   = OpenTelemetry.tracer_provider.tracer("orphans")

tracer.in_span("request") do
  3.times.map do |i|
    Thread.new do
      tracer.in_span("worker_#{i}") { sleep 0.001 }
    end
  end.each(&:join)
end

TalkDemo.print_tree("02 — Thread.new (orphans!):", exporter)
