# Multi-tenant observability in a single Ruby process.
#
# Run with:
#   RUBY_BOX=1 bundle exec ruby examples/box_multitenant_demo.rb
#
# What this demonstrates:
#
#   * Two "tenants" live in the same Ruby process, each in its own Ruby::Box.
#   * Each tenant loads its own copy of Sashiko, its own OTel SDK, its own
#     in-memory exporter, and its own version of a stub Anthropic client.
#   * Both tenants run the SAME business code through the SAME API surface.
#   * Tenant A's spans stay in Tenant A's exporter. Tenant B's spans stay
#     in Tenant B's exporter. Main process's world is never touched.
#
# Vanilla `prepend` is process-global, so two tenants in one process
# can't independently instrument the same class. Ruby 4.0's Box lifts
# that limitation by giving each Box its own loading namespace.
#
# IMPORTANT: inside a Box, use OpenTelemetry's tracer directly rather
# than Sashiko.tracer. Ruby::Box does not isolate OpenTelemetry's module
# state, so Sashiko.tracer is memoized to main's tracer on first call.
# Reach the box-local SDK via OpenTelemetry.tracer_provider.tracer(...).

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "sashiko"

unless Sashiko::Box.enabled?
  abort "Run with RUBY_BOX=1 to enable Ruby::Box."
end

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

    # Tenant-local "Anthropic" stub — each box has its own version
    module Anthropic
      class Messages
        def create(**params)
          sleep 0.005
          tracer = OpenTelemetry.tracer_provider.tracer("anthropic-stub")
          tracer.in_span("chat \#{params[:model]}",
                         attributes: { "gen_ai.system" => "anthropic",
                                       "gen_ai.request.model" => params[:model] }) do
            { id: "#{label}_resp", model: params[:model] }
          end
        end
      end
    end

    # Run tenant workload — each call emits a chat span through THIS box's
    # OTel instance and ends up in THIS box's exporter.
    tracer = OpenTelemetry.tracer_provider.tracer("tenant")
    tracer.in_span("tenant.request", attributes: { "tenant" => #{label.inspect} }) do
      3.times { Anthropic::Messages.new.create(model: "claude-sonnet-4-6") }
    end

    TENANT_EXPORTER.finished_spans.map { |s| [s.name, s.attributes["tenant"] || s.attributes["gen_ai.request.model"]] }
  RUBY
end

# -----------------------------------------------------------------------

tenant_a_box = Sashiko::Box.new
tenant_a_spans = tenant_a_box.eval(tenant_setup("tenant-A"))

tenant_b_box = Sashiko::Box.new
tenant_b_spans = tenant_b_box.eval(tenant_setup("tenant-B"))

# -----------------------------------------------------------------------

def print_spans(label, spans)
  puts "  #{label}: #{spans.length} span(s)"
  spans.each { |name, detail| puts "    - #{name}  detail=#{detail.inspect}" }
end

puts "=" * 70
puts "After running both tenants:"
puts "=" * 70
print_spans("tenant-A exporter", tenant_a_spans)
print_spans("tenant-B exporter", tenant_b_spans)

puts
puts "=" * 70
puts "Isolation verification:"
puts "=" * 70
puts "  Main process sees Anthropic class? #{defined?(Anthropic).inspect}"
puts "  tenant-A sees Anthropic? #{
  tenant_a_box.eval('defined?(Anthropic)').inspect
}"
puts "  tenant-B sees tenant-A's TENANT_EXPORTER? #{
  tenant_b_box.eval('defined?(TENANT_A_EXPORTER)').inspect
}"

puts
puts "Result: main is pristine, both tenants have their own Anthropic class,"
puts "OTel SDK, and exporter. Spans stay in their own Box."
