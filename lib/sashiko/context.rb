module Sashiko
  # Helpers for propagating OTel Context across concurrency boundaries.
  #
  # OpenTelemetry::Context uses fiber-local storage, so spans started in a
  # new Thread or detached Fiber have no parent by default. These helpers
  # capture the caller's Context and re-attach it inside the forked unit of
  # work, so parent/child span relationships survive the boundary.
  module Context
    class << self
      # Yield the current OTel Context. Typically captured at submit time,
      # then passed to #attach inside the worker.
      def current = OpenTelemetry::Context.current

      # Run `block` with the given Context attached. Caller owns detach
      # ordering — use #with for the auto-managed form.
      def with(context, &) = OpenTelemetry::Context.with_current(context, &)

      # Thread.new { work } that preserves the current OTel Context.
      # Returns the Thread so callers can .join / .value as usual.
      def thread(&block)
        ctx = current
        Thread.new { with(ctx, &block) }
      end

      # Fiber.new { work } that preserves the current OTel Context.
      # Returns the Fiber; caller resumes it.
      def fiber(&block)
        ctx = current
        Fiber.new { with(ctx, &block) }
      end

      # Map block over enumerable, each element executed on its own thread,
      # all with the Context captured at call time. Returns [result, ...] in
      # input order. Useful for fanning out instrumented work (e.g. parallel
      # tool calls, parallel HTTP) from inside a traced method.
      def parallel_map(enumerable, &block)
        ctx = current
        enumerable
          .map.with_index { |item, i| Thread.new { [i, with(ctx) { block.call(item) }] } }
          .map(&:value)
          .sort_by(&:first)
          .map(&:last)
      end

      # ---- Cross-boundary propagation via W3C Trace Context ---------------
      #
      # Serialize the current OTel Context into a plain Hash of string
      # headers (traceparent, tracestate). The hash contains only strings,
      # so it's Ractor-shareable as-is, JSON-serializable, and safe to pass
      # through any boundary:
      #   - Sidekiq/ActiveJob job arguments
      #   - Kafka/SQS message attributes
      #   - Ractor.new(...) arguments
      #   - HTTP request headers
      def carrier
        h = {}
        OpenTelemetry.propagation.inject(h)
        Ractor.make_shareable(h)
      end

      # Re-attach a context captured via #carrier. Yields with that context
      # as current. The extracted context is "remote" from OTel's POV, so
      # spans started inside become children of the original span.
      def attach(carrier, &) = with(OpenTelemetry.propagation.extract(carrier), &)
    end
  end
end
