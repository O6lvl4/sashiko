$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "json"
require "opentelemetry/sdk"
require "sashiko"

module TestHelper
  def self.setup_exporter
    @exporter ||= begin
      exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      OpenTelemetry::SDK.configure do |c|
        c.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
        )
      end
      exporter
    end
  end

  def self.exporter
    setup_exporter
  end
end
