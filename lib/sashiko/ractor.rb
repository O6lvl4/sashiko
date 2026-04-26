# frozen_string_literal: true

module Sashiko
  # Ractor-based parallel execution with span replay.
  #
  # The problem: OpenTelemetry Ruby cannot emit spans inside a Ractor
  # because its module state carries unshareable instance variables
  # (mutexes, propagation). Upstream OTel has acknowledged this as a
  # blocker for Ractor adoption.
  #
  # The workaround: inside the Ractor, record spans as plain frozen
  # Data values (no OTel dependency), send them via Ractor::Port to the
  # main Ractor, and *replay* them there as real OTel spans with their
  # original start/end timestamps and parent linkage.
  #
  # Caveats: trace_id / span_id are assigned at replay time on the main
  # side; OpenTelemetry::Baggage set inside the Ractor is not propagated
  # out; sampling decisions happen at replay time.
  module Ractor
    class NonShareableReceiverError < ArgumentError; end

    # Immutable record of a span that occurred inside a Ractor. Replayed
    # on the main Ractor as an OTel span with these exact values.
    SpanEvent = Data.define(:id, :parent_id, :name, :kind, :attributes, :start_ns, :end_ns, :status_error)

    # In-Ractor recorder that collects SpanEvents. One instance per worker
    # Ractor, accessed via Recorder.current (thread-local inside the Ractor).
    class Recorder
      # Take a wall-clock anchor once at recorder construction, then drive
      # all per-span timestamps from the monotonic clock relative to that
      # anchor. This gives OTel the wall-clock timestamps it expects while
      # keeping span durations immune to NTP / system-time jumps that hit
      # mid-batch.
      def initialize
        @events       = [] #: Array[SpanEvent]
        @stack        = [] #: Array[Integer]
        @next_id      = 0
        @wall_anchor  = Process.clock_gettime(Process::CLOCK_REALTIME,  :nanosecond)
        @mono_anchor  = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      end

      attr_reader :events

      def span(name, kind: :internal, attributes: nil)
        id = (@next_id += 1)
        parent_id = @stack.last
        start_ns = now_ns
        @stack.push(id)
        error = nil
        begin
          result = block_given? ? yield : nil
        rescue => e
          error = e.message
          raise
        ensure
          @events << SpanEvent.new(
            id:, parent_id:, name:, kind:,
            attributes: deep_freeze(attributes || {}),
            start_ns:, end_ns: now_ns,
            status_error: error,
          )
          @stack.pop
        end
        result
      end

      def self.current = ::Thread.current[:sashiko_recorder] ||= new
      def self.install(recorder) = ::Thread.current[:sashiko_recorder] = recorder
      def self.drain_events!
        r = ::Thread.current[:sashiko_recorder]
        ::Thread.current[:sashiko_recorder] = nil
        empty = [] #: Array[SpanEvent]
        events = r ? r.events : empty
        events.map { |e| ::Ractor.make_shareable(e) }.freeze
      end

      private

      def now_ns
        @wall_anchor + (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - @mono_anchor)
      end

      def deep_freeze(hash)
        acc = {} #: Hash[String, untyped]
        hash.each_with_object(acc) { |(k, v), h| h[k.to_s.freeze] = v.frozen? ? v : v.dup.freeze }.freeze
      end
    end

    class << self
      # Record a nested span inside a Ractor worker. Produces a SpanEvent
      # that will be replayed as an OTel span on the main Ractor. The API
      # mirrors tracer.in_span, but it runs without the OTel runtime —
      # see the module-level caveats about trace_id, baggage, and sampling.
      #
      #   module Compute
      #     def self.run(n)
      #       Sashiko::Ractor.span("phase1") { work1(n) }
      #       Sashiko::Ractor.span("phase2") { work2(n) }
      #     end
      #   end
      def span(name, kind: :internal, attributes: nil, &) = Recorder.current.span(name, kind:, attributes:, &)

      # Map `method` over `items` in parallel Ractors. Each Ractor's call
      # is recorded as a root span (named after the method), plus any
      # nested Sashiko::Ractor.span calls inside. All events are shipped
      # back via Ractor::Port and replayed on the main Ractor under the
      # current trace context — so the whole tree shows up as children of
      # the span wrapping this parallel_map call.
      def parallel_map(items, via:, tracer: nil)
        raise ArgumentError, "via: must be a Method object" unless via.is_a?(Method)
        receiver    = via.receiver
        method_name = via.name
        unless ::Ractor.shareable?(receiver)
          raise NonShareableReceiverError,
            "method receiver #{receiver.inspect} must be Ractor-shareable (a Module or frozen class)"
        end
        root_name = "#{receiver}.#{method_name}"
        carrier   = Sashiko::Context.carrier
        # Resolve once on the main side so every replayed batch lands on
        # the same tracer (Box-local if the caller passed one).
        emit_tracer = tracer || Sashiko.tracer

        ports = items.each_with_index.map do |item, i|
          port = ::Ractor::Port.new
          ::Ractor.new(port, receiver, method_name, item, i, root_name, carrier) do |p, r, m, it, idx, rn, _c|
            Sashiko::Ractor::Recorder.install(Sashiko::Ractor::Recorder.new)
            result = nil
            error  = nil
            begin
              result = Sashiko::Ractor.span(rn, attributes: { "item.index" => idx }) do
                r.public_send(m, it)
              end
            rescue => e
              error = "#{e.class}: #{e.message}"
            end
            p.send([idx, result, Sashiko::Ractor::Recorder.drain_events!, error])
          end
          port
        end

        results = Array.new(items.size)
        errors  = [] #: Array[String]
        ports.size.times do
          idx, value, events, error = ports.shift.receive
          Sink.replay(events, parent_carrier: carrier, tracer: emit_tracer)
          if error
            errors << "item[#{idx}]: #{error}"
          else
            results[idx] = value
          end
        end
        raise "Ractor worker failures: #{errors.join("; ")}" unless errors.empty?
        results
      end
    end

    # Main-Ractor replayer. Takes a batch of SpanEvents from a worker and
    # re-emits them as real OTel spans with their recorded timing and the
    # correct parent chain.
    module Sink
      class << self
        def replay(events, parent_carrier:, tracer: nil)
          return if events.empty?
          tracer ||= Sashiko.tracer
          parent_ctx = OpenTelemetry.propagation.extract(parent_carrier)
          replayed = {} #: Hash[Integer, untyped]

          events.sort_by(&:id).each do |event|
            ctx = if event.parent_id.nil?
                    parent_ctx
                  elsif (parent = replayed[event.parent_id])
                    OpenTelemetry::Trace.context_with_span(parent)
                  else
                    parent_ctx
                  end

            OpenTelemetry::Context.with_current(ctx) do
              span = tracer.start_span(
                event.name,
                kind: event.kind,
                attributes: event.attributes,
                start_timestamp: Time.at(0, event.start_ns, :nanosecond),
              )
              if event.status_error
                span.status = OpenTelemetry::Trace::Status.error(event.status_error)
              end
              span.finish(end_timestamp: Time.at(0, event.end_ns, :nanosecond))
              replayed[event.id] = span
            end
          end
        end
      end
    end
  end
end
