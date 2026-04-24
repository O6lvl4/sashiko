module Sashiko
  # Ractor-based parallel execution using Ruby 4.0's Ractor::Port API.
  #
  # This runs each item in a genuinely isolated Ractor — true parallel
  # execution on multiple cores, no GVL — as opposed to
  # Sashiko::Context.parallel_map which uses Threads that share the
  # parent's OTel Context via fiber-local storage.
  #
  # ## API
  #
  #   module Compute
  #     def self.heavy(n) = (1..n).sum
  #   end
  #
  #   Sashiko::Ractor.parallel_map([1000, 2000, 3000], via: Compute.method(:heavy))
  #   # => [500500, 2001000, 4501500]
  #
  # ## Why a Method object instead of a block?
  #
  # Ractors can only receive shareable values across boundaries. Plain
  # Procs/lambdas close over their creation scope's self and locals, so
  # they're never shareable — Ractor.make_shareable raises on them.
  # A Method object, however, decomposes into its receiver + method name,
  # both of which ARE shareable when the receiver is a Module / frozen
  # class. So we require that form and unpack it internally.
  #
  # ## Limitations
  #
  # Spans cannot currently be emitted inside a Ractor — OpenTelemetry
  # Ruby's module state carries unshareable instance variables. Use this
  # for CPU-parallel compute and emit spans in the main Ractor around the
  # parallel_map call. The carrier captured at call time is deep-frozen
  # and Ractor-shareable, so when upstream OTel becomes Ractor-safe, the
  # existing captured carrier will flow through unchanged.
  module Ractor
    class NonShareableReceiverError < ArgumentError; end

    class << self
      # Map `method` over `items` in parallel Ractors, collecting results
      # via Ractor::Port. Returns results in input order.
      #
      # @param items [Array] enumerable of items to process
      # @param via [Method] a Method whose receiver is Ractor-shareable
      # @return [Array] results in input order
      # @raise [NonShareableReceiverError] if `via.receiver` isn't shareable
      def parallel_map(items, via:)
        raise ArgumentError, "via: must be a Method object" unless via.is_a?(Method)
        receiver    = via.receiver
        method_name = via.name
        unless ::Ractor.shareable?(receiver)
          raise NonShareableReceiverError,
            "method receiver #{receiver.inspect} must be Ractor-shareable (a Module or frozen class)"
        end

        carrier = Sashiko::Context.carrier
        ports = items.each_with_index.map do |item, i|
          port = ::Ractor::Port.new
          ::Ractor.new(port, receiver, method_name, item, i, carrier) do |p, r, m, it, idx, _c|
            p.send([idx, r.public_send(m, it)])
          end
          port
        end

        results = Array.new(items.size)
        ports.size.times do
          idx, value = ports.shift.receive
          results[idx] = value
        end
        results
      end
    end
  end
end
