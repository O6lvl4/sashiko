$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "sashiko"
require "sashiko/adapters/faraday"
require "faraday"

# ---- Span collector: visualize as a tree, not just a flat list ----------

class TreeExporter
  def initialize
    @spans = []
  end

  def export(spans, _timeout: nil)
    @spans.concat(spans)
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end
  def force_flush(timeout: nil); OpenTelemetry::SDK::Trace::Export::SUCCESS; end
  def shutdown(timeout: nil);    OpenTelemetry::SDK::Trace::Export::SUCCESS; end

  def dump(label)
    puts
    puts "━" * 70
    puts " #{label}"
    puts "━" * 70
    by_parent = @spans.group_by { |s| s.parent_span_id.unpack1("H*") }
    traces = @spans.group_by(&:hex_trace_id)
    traces.each do |trace_id, spans_in_trace|
      puts "Trace #{trace_id[0, 8]}:"
      roots = spans_in_trace.select { |s| s.parent_span_id.unpack1("H*") == ("0" * 16) }
      roots.each { |root| print_tree(root, by_parent, 0) }
    end
    @spans.clear
  end

  private

  def print_tree(span, by_parent, depth)
    pad = "  " * depth
    ms  = ((span.end_timestamp - span.start_timestamp) / 1_000_000.0).round(1)
    meta = if span.attributes["http.response.status_code"]
             " [HTTP #{span.attributes["http.response.status_code"]}]"
           elsif span.attributes["repo.name"]
             " [#{span.attributes["repo.name"]}]"
           else
             ""
           end
    puts "#{pad}├─ #{span.name} (#{ms}ms)#{meta}"
    children = by_parent[span.span_id.unpack1("H*")] || []
    children.each { |c| print_tree(c, by_parent, depth + 1) }
  end
end

exporter = TreeExporter.new
OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
end

REPOS = ["rails/rails", "sinatra/sinatra", "hanami/hanami"].freeze
tracer = OpenTelemetry.tracer_provider.tracer("demo")

# ========================================================================
# SCENARIO A: naive — plain OTel, Thread.new for parallelism
# ========================================================================

tracer.in_span("scenario_A: fetch stars for 3 repos") do
  # No Faraday instrumentation, no Sashiko context propagation.
  http = Faraday.new("https://api.github.com") { |f| f.adapter Faraday.default_adapter }

  threads = REPOS.map do |repo|
    Thread.new do
      # Manual span, inside a new Thread → loses parent context.
      tracer.in_span("fetch #{repo}") do |s|
        s.set_attribute("repo.name", repo)
        resp = http.get("/repos/#{repo}")
        s.set_attribute("stars", JSON.parse(resp.body)["stargazers_count"])
      end
    end
  end
  threads.each(&:join)
end

exporter.dump("SCENARIO A  (plain OTel, Thread.new)")

# ========================================================================
# SCENARIO B: Sashiko — Traced DSL + Faraday adapter + Context.parallel_map
# ========================================================================

class GithubInspector
  extend Sashiko::Traced

  HTTP = Faraday.new("https://api.github.com") do |f|
    f.use Sashiko::Adapters::Faraday::Middleware   # ← HTTP 自動計装
    f.adapter Faraday.default_adapter
  end

  trace :fetch_stars_for_all, attributes: ->(repos) { { "batch.size" => repos.length } }
  def fetch_stars_for_all(repos)
    # parallel_map が OTel Context を thread 跨ぎで引き継ぐ
    Sashiko::Context.parallel_map(repos) { |r| fetch_one(r) }
  end

  trace :fetch_one, attributes: ->(repo) { { "repo.name" => repo } }
  def fetch_one(repo)
    resp = HTTP.get("/repos/#{repo}")
    JSON.parse(resp.body).fetch("stargazers_count")
  end
end

Sashiko.tracer.in_span("scenario_B: fetch stars for 3 repos") do
  inspector = GithubInspector.new
  stars = inspector.fetch_stars_for_all(REPOS)
  puts
  puts "Result: #{REPOS.zip(stars).to_h.inspect}"
end

exporter.dump("SCENARIO B  (Sashiko)")
