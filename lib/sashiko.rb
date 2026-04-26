# frozen_string_literal: true

require "opentelemetry/sdk"

require_relative "sashiko/version"
require_relative "sashiko/traced"
require_relative "sashiko/context"
require_relative "sashiko/ractor"
require_relative "sashiko/box"

# Adapters are NOT auto-required. Each is a thin optional layer over the core.
#   require "sashiko/adapters/faraday"
#   require "sashiko/adapters/anthropic"
module Sashiko
  DEFAULT_TRACER_NAME = "sashiko" unless const_defined?(:DEFAULT_TRACER_NAME)

  # The `respond_to?(:tracer)` guard prevents redefinition when sashiko
  # is re-required inside a Ruby::Box. Without it, the box's
  # re-evaluation of this file would re-run `class << self; def tracer`
  # and rebind the method's constant resolution to the box's scope,
  # which then surfaces in *main* as well (Sashiko is a shared module).
  # With the guard, main's `Sashiko.tracer` keeps resolving against
  # main's OpenTelemetry, and an explicit `tracer:` keyword (or a raw
  # `OpenTelemetry.tracer_provider.tracer(...)` call) is the documented
  # way to reach a Box-local tracer from within box code.
  #
  # Memoization is for performance: `OpenTelemetry.tracer_provider.tracer`
  # is internally cached by (name, version), so this just avoids one
  # extra method dispatch per `Sashiko.tracer` call.
  unless respond_to?(:tracer)
    class << self
      def tracer = @tracer ||= OpenTelemetry.tracer_provider.tracer(DEFAULT_TRACER_NAME, VERSION)
    end
  end
end
