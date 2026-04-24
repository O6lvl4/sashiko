require_relative "test_helper"
require "sashiko/adapters/anthropic"

# These tests only run when Ruby 4.0's experimental Ruby::Box feature is
# enabled (process started with RUBY_BOX=1). CI sets this explicitly in
# the box job; local runs without the flag are skipped, not failed.
class BoxTest < Minitest::Test
  def setup
    skip "Ruby::Box not enabled (start ruby with RUBY_BOX=1)" unless box_enabled?
  end

  def test_instrument_in_box_does_not_leak_prepend_to_main
    box = Ruby::Box.new
    box.eval(<<~RUBY)
      module BoxedStub
        class Client
          def create(**p) = { model: p[:model], usage: { input_tokens: 1, output_tokens: 1 } }
        end
      end
    RUBY

    Sashiko::Adapters::Anthropic.instrument_in_box!(box, "BoxedStub::Client")

    # Inside the box, the class IS instrumented.
    boxed_flag = box.eval("BoxedStub::Client.instance_variable_get(:@__sashiko_instrumented)")
    assert_equal true, boxed_flag

    # The main process was never touched — BoxedStub is not even defined here.
    assert_nil defined?(BoxedStub)
  end

  def test_sashiko_box_helpers_bootstrap_isolated_sashiko
    box = Sashiko::Box.new_with_sashiko
    # The box has its own Sashiko constant, separate object from main's.
    box_has_sashiko = box.eval("defined?(Sashiko::Traced)")
    assert_equal "constant", box_has_sashiko
  end

  def test_two_boxes_have_isolated_state
    box_a = Sashiko::Box.new_with_sashiko
    box_b = Sashiko::Box.new_with_sashiko

    box_a.eval("module BoxA_OnlyMarker; end")
    box_b.eval("module BoxB_OnlyMarker; end")

    # Each box sees its own marker, neither sees the other's, neither leaks to main.
    assert_equal "constant", box_a.eval("defined?(BoxA_OnlyMarker)")
    assert_nil              box_a.eval("defined?(BoxB_OnlyMarker)")
    assert_equal "constant", box_b.eval("defined?(BoxB_OnlyMarker)")
    assert_nil              box_b.eval("defined?(BoxA_OnlyMarker)")
    assert_nil defined?(BoxA_OnlyMarker)
    assert_nil defined?(BoxB_OnlyMarker)
  end

  def test_multi_tenant_exporters_do_not_cross_contaminate
    tenant_setup = ->(label) {
      <<~RUBY
        require "opentelemetry/sdk"
        TENANT_EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        OpenTelemetry::SDK.configure do |c|
          c.add_span_processor(
            OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(TENANT_EXPORTER)
          )
        end
        Sashiko.tracer.in_span("work", attributes: { "tenant" => #{label.inspect} }) {}
        TENANT_EXPORTER.finished_spans.map { |s| s.attributes["tenant"] }
      RUBY
    }
    a_tenants = Sashiko::Box.new_with_sashiko.eval(tenant_setup.call("alice"))
    b_tenants = Sashiko::Box.new_with_sashiko.eval(tenant_setup.call("bob"))
    assert_equal ["alice"], a_tenants
    assert_equal ["bob"],   b_tenants
  end

  private

  def box_enabled?
    defined?(Ruby::Box) && Ruby::Box.enabled?
  end
end
