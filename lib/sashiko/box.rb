module Sashiko
  # Ergonomic wrapper around Ruby 4.0's experimental Ruby::Box.
  #
  # Ruby::Box creates a fully isolated loading namespace — requires, class
  # definitions, monkey-patches, and even OTel tracer providers loaded
  # inside a Box are invisible to the rest of the process. That makes Box
  # uniquely suited to multi-tenant observability: different tenants can
  # share a Ruby process while each maintains its own Sashiko instance,
  # its own instrumented classes, and its own OTel exporter.
  #
  # Example — two tenants with isolated instrumentation:
  #
  #   tenant_a = Sashiko::Box.new_with_sashiko
  #   tenant_a.eval(<<~RUBY)
  #     OpenTelemetry::SDK.configure { |c| c.service_name = "tenant-a" }
  #     # ... load tenant-a adapters / instrument classes ...
  #   RUBY
  #
  #   tenant_b = Sashiko::Box.new_with_sashiko
  #   tenant_b.eval(<<~RUBY)
  #     OpenTelemetry::SDK.configure { |c| c.service_name = "tenant-b" }
  #   RUBY
  #
  # Each tenant's spans / exporters / instrumented classes are invisible
  # to the other and to main. Ruby 4's "yet another Ractor-safe escape
  # hatch for observability", but for loading-time isolation rather than
  # execution-time.
  module Box
    class NotEnabledError < StandardError
      def initialize
        super("Ruby::Box is not enabled. Start Ruby with RUBY_BOX=1.")
      end
    end

    class << self
      def enabled? = defined?(::Ruby::Box) && ::Ruby::Box.enabled?

      # Create a new Ruby::Box. Raises NotEnabledError when not under
      # RUBY_BOX=1 so callers fail fast instead of getting obscure errors.
      def new
        raise NotEnabledError unless enabled?
        ::Ruby::Box.new
      end

      # Create a new Ruby::Box with Sashiko pre-required inside it. The
      # box can then `eval` user code that uses `Sashiko::Traced`,
      # `Sashiko::Context`, etc. as if it were main-process code — except
      # all state stays inside the box.
      def new_with_sashiko(lib_path: default_lib_path)
        box = new
        box.eval(<<~RUBY)
          $LOAD_PATH.unshift(#{lib_path.inspect})
          require "sashiko"
        RUBY
        box
      end

      private

      def default_lib_path
        $LOAD_PATH.find { File.exist?(File.join(_1, "sashiko.rb")) } ||
          File.expand_path("..", __dir__)
      end
    end
  end
end
