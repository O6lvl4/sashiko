# frozen_string_literal: true

# Shared helpers for the talk-arc demos. Keeps each numbered demo
# under ~50 lines so it fits on a slide.

require "opentelemetry/sdk"

module TalkDemo
  class << self
    def setup_otel
      exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      OpenTelemetry::SDK.configure do |c|
        c.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
        )
      end
      exporter
    end

    def print_tree(label, exporter)
      puts label
      spans = exporter.finished_spans
      by_parent = spans.group_by { |s| s.parent_span_id.unpack1("H*") }
      roots = spans.select { |s| s.parent_span_id.unpack1("H*") == ("0" * 16) }
      puts "  (#{roots.length} root span#{roots.length == 1 ? "" : "s"})" if roots.length != 1 || ENV["VERBOSE"]
      roots.each { |r| print_node(r, by_parent, 1) }
      puts
    end

    private

    def print_node(span, by_parent, depth)
      pad = "  " * depth
      puts "#{pad}├─ #{span.name}"
      (by_parent[span.span_id.unpack1("H*")] || []).each { |c| print_node(c, by_parent, depth + 1) }
    end
  end
end
