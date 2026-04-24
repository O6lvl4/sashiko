$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "sashiko"

# ---- Minimal span printer ---------------------------------------------

class LineExporter
  def export(spans, _timeout: nil)
    spans.each do |s|
      attrs = s.attributes.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      status = s.status.code == OpenTelemetry::Trace::Status::ERROR ? "ERROR" : "OK"
      duration_ms = ((s.end_timestamp - s.start_timestamp) / 1_000_000.0).round(2)
      parent = s.parent_span_id.unpack1("H*")
      puts "[#{status} #{duration_ms.to_s.rjust(6)}ms parent=#{parent[0, 4]}] #{s.name}  #{attrs}"
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

# ---- Example: job runner that fans out work across threads -----------
#
# Demonstrates the two durable parts of sashiko:
#   1. Traced DSL wraps user methods.
#   2. Sashiko::Context.parallel_map keeps parent/child span links alive
#      across Thread boundaries — something OTel's fiber-local context
#      does NOT do by default.

class JobRunner
  extend Sashiko::Traced

  trace :run, attributes: ->(jobs) { { "job.count" => jobs.length } }
  def run(jobs)
    # Without Sashiko::Context.parallel_map, each worker thread would start
    # a fresh root trace and you'd lose the connection to `run`.
    Sashiko::Context.parallel_map(jobs) { |j| process(j) }
  end

  trace :process, attributes: ->(job) { { "job.id" => job[:id] } }
  def process(job)
    fetch(job[:url])
    compute(job[:id])
  end

  trace :fetch, kind: :client, attributes: ->(url) { { "url.full" => url } }
  def fetch(_url)
    sleep(0.005 + rand * 0.01)
    "ok"
  end

  trace :compute
  def compute(id)
    sleep(0.002)
    id * 2
  end
end

puts "--- running 3 jobs in parallel ---"
jobs = [
  { id: 1, url: "https://api.example.com/a" },
  { id: 2, url: "https://api.example.com/b" },
  { id: 3, url: "https://api.example.com/c" },
]
results = JobRunner.new.run(jobs)
puts "--- results: #{results.inspect} ---"
