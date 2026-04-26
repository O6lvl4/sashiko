# frozen_string_literal: true

# Talk demo 07 — Tracer DI: every place Sashiko emits a span accepts
# an explicit `tracer:` keyword. Spans routed through it bypass the
# memoized `Sashiko.tracer` and end up on the chosen provider — no
# Box, no global mutation, no surprises.
#
# Run:  bundle exec ruby examples/talk/07_tracer_di.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sashiko"
require "opentelemetry/sdk"

# Two independent providers / exporters.
def make_pipe(name)
  exp = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
  prov = OpenTelemetry::SDK::Trace::TracerProvider.new
  prov.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exp))
  [exp, prov.tracer(name)]
end

red_exp, red_tracer = make_pipe("red")
blue_exp, blue_tracer = make_pipe("blue")

# Two services routed to different tracers via DI.
class RedService
  extend Sashiko::Traced
  TRACER = nil   # filled in below
  def work; "red-#{rand(99)}"; end
end
class BlueService
  extend Sashiko::Traced
  def work; "blue-#{rand(99)}"; end
end

RedService.send(:trace,  :work, tracer: red_tracer)
BlueService.send(:trace, :work, tracer: blue_tracer)

RedService.new.work
BlueService.new.work

puts "07 — `tracer:` DI routing:"
puts
puts "  red exporter:  #{red_exp.finished_spans.map(&:name).inspect}"
puts "  blue exporter: #{blue_exp.finished_spans.map(&:name).inspect}"
puts
puts "  ⇒ Each service's spans land only on its own tracer's pipeline."
puts "    The same pattern keeps a Ruby::Box-local SDK from poisoning"
puts "    main: instrument with `tracer: OpenTelemetry.tracer_provider"
puts "    .tracer(...)` evaluated inside the box."
