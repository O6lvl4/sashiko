# frozen_string_literal: true

# Talk demo 04 — Ractor wall: vanilla OpenTelemetry literally cannot
# emit spans from inside a Ractor. The SDK's module state holds
# non-shareable instance variables (mutexes, propagation), so reaching
# `OpenTelemetry.tracer_provider` from inside a Ractor raises
# `Ractor::IsolationError`.
#
# Run:  bundle exec ruby examples/talk/04_ractor_isolation_error.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sashiko"
require_relative "_tree"

TalkDemo.setup_otel

puts "04 — calling OpenTelemetry.tracer_provider from inside a Ractor:"
puts

# Silence the dying-thread report — we *want* the Ractor to fail and
# we'll print the cause ourselves below.
Thread.report_on_exception = false

begin
  Ractor.new do
    OpenTelemetry.tracer_provider.tracer("inside").in_span("never_emitted") {}
  end.value
  puts "  unexpectedly succeeded — has OTel SDK become Ractor-shareable?"
rescue Ractor::RemoteError => e
  cause = e.cause
  puts "  #{cause.class}: #{cause.message}"
end

puts
puts "  ⇒ Vanilla OpenTelemetry is unusable inside a Ractor."
puts "    Sashiko's solution: record SpanEvents inside the Ractor,"
puts "    replay them as real spans on the main side. See demo 05."
