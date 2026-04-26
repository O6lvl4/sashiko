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

  # Memoized to anchor `Sashiko.tracer` to the OpenTelemetry tracer
  # provider that was current when first called — typically main's. We
  # would prefer to resolve `OpenTelemetry.tracer_provider` on every call,
  # but Ruby::Box does not isolate the OpenTelemetry module's state:
  # `OpenTelemetry::SDK.configure` from inside a Box mutates the same
  # `OpenTelemetry.tracer_provider` slot that main reads, so a
  # late-resolving `Sashiko.tracer` would silently flip mid-process.
  # Inside a Box, do not call `Sashiko.tracer` — use
  # `OpenTelemetry.tracer_provider.tracer(...)` directly so the box's
  # SDK is reached.
  unless respond_to?(:tracer)
    class << self
      def tracer = @tracer ||= OpenTelemetry.tracer_provider.tracer(DEFAULT_TRACER_NAME, VERSION)
    end
  end
end
