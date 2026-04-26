# frozen_string_literal: true

module Sashiko
  # Wrapper around Ruby 4.0's experimental Ruby::Box.
  #
  # Ruby::Box creates an isolated loading namespace — requires, class
  # definitions, monkey-patches, and OTel tracer providers loaded inside
  # a Box are invisible to the rest of the process. That makes Box useful
  # for multi-tenant observability inside a single Ruby process: each
  # tenant gets its own Sashiko, its own OTel exporter, and its own
  # instrumented classes.
  #
  # Requires the process to be started with RUBY_BOX=1 (Box is opt-in
  # and experimental in Ruby 4.0).
  #
  #   tenant_a = Sashiko::Box.new
  #   tenant_a.eval(<<~RUBY)
  #     OpenTelemetry::SDK.configure { |c| c.service_name = "tenant-a" }
  #     # ... load tenant-a adapters / instrument classes ...
  #   RUBY
  #
  # If you want a bare Ruby::Box without Sashiko pre-required, use
  # ::Ruby::Box.new directly.
  module Box
    class NotEnabledError < StandardError
      def initialize
        super("Ruby::Box is not enabled. Start Ruby with RUBY_BOX=1.")
      end
    end

    class << self
      def enabled? = !!(defined?(::Ruby::Box) && ::Ruby::Box.enabled?)

      # Create a new Ruby::Box with Sashiko pre-required inside it. The
      # box can then `eval` user code that uses Sashiko::Traced,
      # Sashiko::Context, etc. as if it were main-process code — except
      # all state stays inside the box.
      #
      # Raises NotEnabledError when not under RUBY_BOX=1 so callers fail
      # fast instead of getting obscure errors.
      def new(lib_path: default_lib_path)
        raise NotEnabledError unless enabled?
        box = ::Ruby::Box.new
        box.eval(<<~RUBY)
          $LOAD_PATH.unshift(#{lib_path.inspect})
          require "sashiko"
        RUBY
        box
      end

      private

      def default_lib_path
        found = $LOAD_PATH.find { |p| File.exist?(File.join(p, "sashiko.rb")) }
        found || File.expand_path("..", __dir__ || ".")
      end
    end
  end
end
