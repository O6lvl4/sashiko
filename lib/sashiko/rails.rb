# frozen_string_literal: true

module Sashiko
  # Rails integration helpers. Loaded explicitly:
  #
  #   require "sashiko/rails"
  #   Sashiko::Rails.install!(notifications: /^my_app\./)
  #
  # The pieces are independent — you can require this file and pick
  # only the helpers you need. None of them monkey-patch Rails.
  module Rails
    class << self
      # Run `block` in a Thread that preserves the current OTel
      # Context, wrapped in a span named `name`. Use this anywhere
      # vanilla `Thread.new` would normally drop the trace context
      # — controllers, jobs, rake tasks, anywhere.
      #
      #   def index
      #     Sashiko::Rails.async("orders.fetch_external") do
      #       ExternalAPI.fetch(...)
      #     end
      #   end
      #
      # Returns the Thread; call `.join` or `.value` as usual.
      # The optional `tracer:` keyword bypasses Sashiko.tracer.
      def async(name, kind: :internal, attributes: nil, tracer: nil)
        Sashiko::Context.thread do
          (tracer || Sashiko.tracer).in_span(name.to_s, kind:, attributes:) do
            yield
          end
        end
      end

      # Subscribe an ActiveSupport::Notifications pattern and emit one
      # OTel span per matched event. The event's payload becomes span
      # attributes (string keys, stringified values). Useful for
      # bridging custom `instrument(...)` calls in your code into the
      # OTel pipeline without re-instrumenting every call site.
      #
      #   ActiveSupport::Notifications.instrument("my_app.lookup", id: 42) { ... }
      #   Sashiko::Rails.bridge_notifications(/^my_app\./)
      #
      # The optional `tracer:` keyword bypasses Sashiko.tracer.
      def bridge_notifications(pattern, tracer: nil)
        unless defined?(::ActiveSupport::Notifications)
          raise "ActiveSupport::Notifications is not available — load `active_support/notifications` first"
        end
        target_tracer = tracer || Sashiko.tracer
        ::ActiveSupport::Notifications.subscribe(pattern) do |name, start, finish, _id, payload|
          attrs = stringify_payload(payload)
          span = target_tracer.start_span(name, attributes: attrs, start_timestamp: start)
          span.finish(end_timestamp: finish)
        end
      end

      # Top-level install hook. Currently delegates to
      # `bridge_notifications` if a pattern is supplied. Add other
      # global setup here as Sashiko::Rails grows.
      def install!(notifications: nil, tracer: nil)
        bridge_notifications(notifications, tracer:) if notifications
        true
      end

      private

      def stringify_payload(payload)
        return {} unless payload.respond_to?(:each_pair)
        out = {} #: Hash[String, untyped]
        payload.each_pair do |k, v|
          key = k.to_s
          out[key] = case v
                    when String, Numeric, true, false, nil then v
                    else                                        v.to_s
                    end
        end
        out
      end
    end

    # Include in ActiveJob classes (typically ApplicationJob) to
    # propagate the OTel trace context across the queue boundary.
    # Works against any ActiveJob backend without backend-specific
    # code: the carrier rides as an extra key on the job's serialized
    # hash, so it survives whatever backend the job lands in.
    #
    #   class ApplicationJob < ActiveJob::Base
    #     include Sashiko::Rails::TracedJob
    #   end
    #
    # On `serialize`, the current `Sashiko::Context.carrier` is
    # attached. On `deserialize`, it's pulled off into an ivar; an
    # `around_perform` callback then attaches the context before
    # invoking the job body. Spans emitted inside `perform` become
    # children of the trace that enqueued the job.
    module TracedJob
      CARRIER_KEY = "_sashiko_trace_carrier"

      module Serialization
        def serialize
          super.merge(CARRIER_KEY => Sashiko::Context.carrier.to_h)
        end

        def deserialize(job_data)
          job_data = job_data.dup
          @__sashiko_trace_carrier = job_data.delete(CARRIER_KEY) || {}
          super(job_data)
        end
      end

      def self.included(base)
        unless defined?(::ActiveJob::Base) && base <= ::ActiveJob::Base
          raise "Sashiko::Rails::TracedJob must be included in an ActiveJob::Base subclass"
        end
        base.prepend(Serialization)
        base.around_perform do |_job, block|
          carrier = (instance_variable_defined?(:@__sashiko_trace_carrier) ? @__sashiko_trace_carrier : {}) #: Hash[String, String]
          if carrier.empty?
            block.call
          else
            Sashiko::Context.attach(carrier) { block.call }
          end
        end
      end
    end
  end
end
