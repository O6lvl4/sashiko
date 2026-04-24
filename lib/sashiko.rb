# If Sashiko was already loaded in the main Ruby (and we're now being
# required again from inside a Ruby::Box), Ruby::Box shares top-level
# modules with main but has its own $LOADED_FEATURES, so we'd re-evaluate
# this file — which would replace Sashiko's class methods with ones
# whose constant-resolution scope is the box's, silently breaking main's
# tracer lookup. Guard against that: skip if we're already loaded.
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

  # Guard against re-definition from inside a Ruby::Box: if Sashiko is
  # already loaded in main, the top-level module is shared with the box,
  # but the box has its own $LOADED_FEATURES and would re-eval this file.
  # Re-evaluating `class << self; def tracer; ...; end` would replace
  # main's tracer method with one whose constant-resolution scope is the
  # box's — silently breaking main's tracer lookup.
  unless respond_to?(:tracer)
    class << self
      attr_writer :tracer

      def tracer = @tracer ||= OpenTelemetry.tracer_provider.tracer(DEFAULT_TRACER_NAME, VERSION)
    end
  end
end
