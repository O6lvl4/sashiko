$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "sashiko"

# Span printer that shows trace_id so we can verify the job ends up in
# the SAME distributed trace as its producer.
class LineExporter
  def export(spans, _timeout: nil)
    spans.each do |s|
      attrs = s.attributes.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      trace = s.hex_trace_id[0, 8]
      parent = s.parent_span_id.unpack1("H*")[0, 4]
      puts "[trace=#{trace} parent=#{parent}] #{s.name}  #{attrs}"
    end
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end
  def force_flush(timeout: nil); OpenTelemetry::SDK::Trace::Export::SUCCESS; end
  def shutdown(timeout: nil);    OpenTelemetry::SDK::Trace::Export::SUCCESS; end
end

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(LineExporter.new)
  )
end

# ---- Minimal in-memory job queue (stands in for Sidekiq / SQS / etc) ---

class FakeQueue
  def initialize; @jobs = Queue.new; end
  def push(job); @jobs << job; end
  def pop; @jobs.pop; end
end

# ---- Producer: enqueues jobs WITH context baked into job args ----------

class Producer
  extend Sashiko::Traced

  def initialize(queue); @queue = queue; end

  trace :enqueue_batch, attributes: ->(items) { { "batch.size" => items.length } }
  def enqueue_batch(items)
    # The `trace_context` field is what makes this a distributed trace.
    # It's just a plain Hash of W3C headers — serializable anywhere.
    items.each do |item|
      @queue.push(
        id: item[:id],
        payload: item[:payload],
        trace_context: Sashiko::Context.carrier,
      )
    end
  end
end

# ---- Worker: pops jobs, re-attaches context, runs traced work ----------

class Worker
  extend Sashiko::Traced

  def initialize(queue); @queue = queue; end

  def run_one
    job = @queue.pop
    # re-attach the producer's trace context before emitting any spans.
    Sashiko::Context.attach(job[:trace_context]) do
      process(job)
    end
  end

  trace :process, attributes: ->(job) { { "job.id" => job[:id] } }
  def process(job)
    # ... imagine DB calls, HTTP calls, tool invocations here ...
    sleep 0.003
    job[:payload].to_s.upcase
  end
end

# ---- Run it ------------------------------------------------------------

queue = FakeQueue.new

# Producer side: single parent span wraps the batch enqueue.
Sashiko.tracer.in_span("web.request POST /orders") do
  Producer.new(queue).enqueue_batch([
    { id: "o-1", payload: "first" },
    { id: "o-2", payload: "second" },
    { id: "o-3", payload: "third" },
  ])
end

puts "--- jobs enqueued; now draining from worker ---"

# Worker side: separate execution, but every job's span ends up in the
# same trace_id as the producer's span.
3.times { Worker.new(queue).run_one }
