# frozen_string_literal: true

# Before/after demo: Thread.new vs Sashiko::Context preserving OTel
# context across a thread boundary.
#
# In Rails / Sidekiq / any Ruby web app, it's common to spawn parallel
# work from inside a request handler. Vanilla `Thread.new` drops the
# OpenTelemetry context, so the spans created inside the threads
# become *root spans*, completely disconnected from the request that
# spawned them.
#
# This demo prints two trace trees:
#
#   Before — naive Thread.new:    request → orphan, orphan, orphan
#   After  — Sashiko::Context:    request → fan-out → child, child, child
#
# Run:  bundle exec ruby examples/thread_fanout_demo.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "sashiko"

# ----- Span collector ---------------------------------------------------

class TreeExporter
  def initialize; @spans = []; end
  def export(spans, _timeout: nil)
    @spans.concat(spans)
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end
  def force_flush(timeout: nil); OpenTelemetry::SDK::Trace::Export::SUCCESS; end
  def shutdown(timeout: nil);    OpenTelemetry::SDK::Trace::Export::SUCCESS; end

  def reset = @spans.clear

  def dump(label)
    puts label
    by_parent = @spans.group_by { |s| s.parent_span_id.unpack1("H*") }
    roots = @spans.select { |s| s.parent_span_id.unpack1("H*") == ("0" * 16) }
    if roots.length > 1
      puts "  (#{roots.length} root spans — orphans!)"
    end
    roots.each { |r| print_tree(r, by_parent, 1) }
    puts
  end

  private

  def print_tree(span, by_parent, depth)
    pad = "  " * depth
    puts "#{pad}├─ #{span.name}"
    (by_parent[span.span_id.unpack1("H*")] || []).each { |c| print_tree(c, by_parent, depth + 1) }
  end
end

exporter = TreeExporter.new
OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
  )
end

# ----- "Controller": handles a request, spawns 3 parallel calls ---------

class Controller
  extend Sashiko::Traced

  trace :handle_request

  def handle_request(case_label)
    if case_label == :before
      threads = 3.times.map do |i|
        Thread.new { fetch_external(i) }   # naive: drops OTel context
      end
      threads.each(&:join)
    else
      Sashiko::Context.parallel_map([0, 1, 2]) do |i|
        fetch_external(i)
      end
    end
  end

  trace :fetch_external, attributes: ->(i) { { "call.index" => i } }
  def fetch_external(i)
    sleep(0.005)
    "ok-#{i}"
  end
end

# ----- Run both cases --------------------------------------------------

ctrl = Controller.new

exporter.reset
ctrl.handle_request(:before)
exporter.dump("Before — naive Thread.new (vanilla OTel drops context)")

exporter.reset
ctrl.handle_request(:after)
exporter.dump("After  — Sashiko::Context.parallel_map (context preserved)")

puts <<~TEXT
  Reading the trees:

    Before: Controller#handle_request and Controller#fetch_external are
            separate root spans. The 3 fetches are orphans — your trace
            backend cannot link them back to the request that spawned them.

    After:  the 3 fetches sit as children of handle_request, exactly as
            you'd expect. No code change in fetch_external itself.

  This boundary-handoff problem is the core thing Sashiko exists to fix,
  on top of vanilla OpenTelemetry. The same pattern applies to Fiber,
  Ractor, queue, and HTTP boundaries — see the other demos.
TEXT
