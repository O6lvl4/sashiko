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

  private

  def box_enabled?
    defined?(Ruby::Box) && Ruby::Box.enabled?
  end
end
