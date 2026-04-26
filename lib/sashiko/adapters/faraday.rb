# frozen_string_literal: true

module Sashiko
  module Adapters
    # Faraday middleware that creates a client-kind span per HTTP request.
    # Usage:
    #   require "sashiko/adapters/faraday"
    #   conn = Faraday.new("https://api.example.com") do |f|
    #     f.use Sashiko::Adapters::Faraday::Middleware
    #     # Or, to inject a specific tracer (e.g. inside a Ruby::Box):
    #     f.use Sashiko::Adapters::Faraday::Middleware,
    #           tracer: OpenTelemetry.tracer_provider.tracer("my-component")
    #   end
    #
    # Attribute names follow OTel HTTP semantic conventions (stable).
    module Faraday
      class Middleware
        def initialize(app, tracer: nil)
          @app    = app
          @tracer = tracer
        end

        def call(env)
          method = env.method.to_s.upcase
          url    = env.url
          attrs = {
            "http.request.method" => method,
            "url.full"            => url.to_s,
            "server.address"      => url.host,
            "server.port"         => url.port,
          }

          # OTel HTTP semconv (stable): client span name is "{METHOD}",
          # e.g. "GET". The previous "HTTP GET" prefix was non-standard.
          (@tracer || Sashiko.tracer).in_span(method, attributes: attrs, kind: :client) do |span|
            response = @app.call(env)
            span.set_attribute("http.response.status_code", response.status)

            case response.status
            in 100..399 # ok, no-op
            in Integer => code
              span.set_attribute("error.type", code.to_s)
              span.status = OpenTelemetry::Trace::Status.error("HTTP #{code}")
            end

            response
          rescue => e
            span.set_attribute("error.type", e.class.name)
            span.record_exception(e)
            span.status = OpenTelemetry::Trace::Status.error(e.message)
            raise
          end
        end
      end
    end
  end
end
