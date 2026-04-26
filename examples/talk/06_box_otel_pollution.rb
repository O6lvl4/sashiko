# frozen_string_literal: true

# Talk demo 06 — Ruby::Box × Sashiko.tracer: where does the span land?
#
# Ruby::Box DOES isolate `OpenTelemetry.tracer_provider` (the object_id
# stays the same in main after the box runs `OpenTelemetry::SDK.configure`).
# So why did Sashiko need a "use OpenTelemetry directly inside the Box"
# escape hatch?
#
# Because `Sashiko.tracer` is defined under a `respond_to?(:tracer)`
# guard at require time. When sashiko is re-required inside a Box, the
# guard skips redefinition — the existing method, whose constant
# resolution scope was main's, stays bound to main's `OpenTelemetry`.
# So `Sashiko.tracer` called from inside a Box still returns *main's*
# tracer. Spans go to main's pipeline, not the box's.
#
# This demo proves it: an in-box span goes to main's exporter.
#
# Run:  RUBY_BOX=1 bundle exec ruby examples/talk/06_box_otel_pollution.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "sashiko"
require_relative "_tree"

unless Sashiko::Box.enabled?
  abort "06 — start Ruby with RUBY_BOX=1 to enable Ruby::Box."
end

main_exporter = TalkDemo.setup_otel
main_provider_id = OpenTelemetry.tracer_provider.object_id

box = Sashiko::Box.new
boxed_provider_id = box.eval(<<~RUBY)
  require "opentelemetry/sdk"
  OpenTelemetry::SDK.configure { |c| c.service_name = "boxed" }
  Sashiko.tracer.in_span("from_inside_box") { }
  OpenTelemetry.tracer_provider.object_id
RUBY

main_after_id = OpenTelemetry.tracer_provider.object_id

puts "06 — Sashiko.tracer routing across a Ruby::Box boundary:"
puts
puts "  main's tracer_provider before box: object_id=#{main_provider_id}"
puts "  main's tracer_provider after  box: object_id=#{main_after_id}"
puts "  box's tracer_provider:             object_id=#{boxed_provider_id}"
puts
puts "  → main's tracer_provider unchanged: #{main_provider_id == main_after_id}"
puts "  → box has its own provider:         #{boxed_provider_id != main_provider_id}"
puts
names = main_exporter.finished_spans.map(&:name)
puts "  spans in main's exporter: #{names.inspect}"
puts
if names.include?("from_inside_box")
  puts "  ⇒ Box.eval('Sashiko.tracer.in_span(...)') landed in MAIN's exporter."
  puts "    Sashiko.tracer is bound to main's OpenTelemetry by design"
  puts "    (require guard prevents redefinition inside the box)."
  puts "    Inside box code, call OpenTelemetry.tracer_provider.tracer(...)"
  puts "    directly, or pass an explicit `tracer:` to Sashiko APIs."
else
  puts "  ⇒ Span did not land in main — Box behavior may have changed."
end
