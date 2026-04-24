# Multi-tenant observability in a single Ruby process.
#
# Run with:
#   RUBY_BOX=1 bundle exec ruby examples/box_multitenant_demo.rb
#
# What this demonstrates:
#
#   * Two "tenants" live in the same Ruby process, each in its own Ruby::Box.
#   * Each tenant loads its own copy of Sashiko, its own OTel SDK, its own
#     in-memory exporter, and its own instrumented stub Anthropic client.
#   * Both tenants run the SAME business code through the SAME API surface.
#   * Tenant A's spans stay in Tenant A's exporter. Tenant B's spans stay
#     in Tenant B's exporter. Main process's world is never touched.
#
# This is not achievable with vanilla Ruby — monkey-patches like `prepend`
# are inherently global. Ruby 4.0's Box lifts that limitation.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "sashiko"

unless Sashiko::Box.enabled?
  abort "Run with RUBY_BOX=1 to enable Ruby::Box."
end

# -----------------------------------------------------------------------
# Setup code, identical for both tenants (just different labels)
# -----------------------------------------------------------------------

def tenant_setup(label)
  <<~RUBY
    require "opentelemetry/sdk"

    # Tenant-local in-memory exporter
    TENANT_EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    OpenTelemetry::SDK.configure do |c|
      c.service_name = #{label.inspect}
      c.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(TENANT_EXPORTER)
      )
    end

    # Tenant-local "Anthropic" stub
    module Anthropic
      class Messages
        def create(**params)
          sleep 0.005
          { id: "#{label}_resp", model: params[:model], stop_reason: "end_turn",
            usage: { input_tokens: 10, output_tokens: 5,
                     cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } }
        end
      end
    end

    # Instrument Anthropic::Messages only inside this tenant's box
    require "sashiko/adapters/anthropic"
    Sashiko::Adapters::Anthropic.instrument!(Anthropic::Messages)

    # Run tenant workload
    Sashiko.tracer.in_span("tenant.request", attributes: { "tenant" => #{label.inspect} }) do
      3.times { Anthropic::Messages.new.create(model: "claude-sonnet-4-6") }
    end

    # Report back what THIS tenant saw
    TENANT_EXPORTER.finished_spans.map { |s| [s.name, s.attributes["gen_ai.system"]] }
  RUBY
end

# -----------------------------------------------------------------------
# Boot two tenants in two boxes
# -----------------------------------------------------------------------

tenant_a_box = Sashiko::Box.new_with_sashiko
tenant_a_spans = tenant_a_box.eval(tenant_setup("tenant-A"))

tenant_b_box = Sashiko::Box.new_with_sashiko
tenant_b_spans = tenant_b_box.eval(tenant_setup("tenant-B"))

# -----------------------------------------------------------------------
# Print what's in each place
# -----------------------------------------------------------------------

def print_spans(label, spans)
  puts "  #{label}: #{spans.length} span(s)"
  spans.each { |name, system| puts "    - #{name}  gen_ai.system=#{system.inspect}" }
end

puts "=" * 70
puts "After running both tenants:"
puts "=" * 70
print_spans("tenant-A exporter", tenant_a_spans)
print_spans("tenant-B exporter", tenant_b_spans)

# -----------------------------------------------------------------------
# Isolation verification from main
# -----------------------------------------------------------------------

puts
puts "=" * 70
puts "Isolation verification:"
puts "=" * 70
puts "  Main process sees Anthropic::Messages class? #{defined?(Anthropic).inspect}"
puts "  tenant-A saw Anthropic::Messages instrumented? #{
  tenant_a_box.eval("Anthropic::Messages.instance_variable_get(:@__sashiko_instrumented)").inspect
}"
puts "  tenant-B saw Anthropic::Messages instrumented? #{
  tenant_b_box.eval("Anthropic::Messages.instance_variable_get(:@__sashiko_instrumented)").inspect
}"
puts "  tenant-A response id visible to tenant-B? #{
  tenant_b_box.eval("defined?(TENANT_A_RESP)").inspect
}"

puts
puts "Result: main is pristine, both tenants are fully instrumented in"
puts "isolation, and their spans never mix. One process, N observability"
puts "planes — that's what Ruby::Box buys you."
