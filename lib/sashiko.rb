require "opentelemetry/sdk"

require_relative "sashiko/version"
require_relative "sashiko/traced"
require_relative "sashiko/context"

# Adapters are NOT auto-required. Each is a thin optional layer over the core.
#   require "sashiko/adapters/faraday"
#   require "sashiko/adapters/anthropic"
module Sashiko
  DEFAULT_TRACER_NAME = "sashiko"

  class << self
    def tracer
      @tracer ||= OpenTelemetry.tracer_provider.tracer(DEFAULT_TRACER_NAME, VERSION)
    end

    attr_writer :tracer
  end
end
