module Sashiko
  module Adapters
    # Faraday middleware that creates a client-kind span per HTTP request.
    # Usage:
    #   require "sashiko/adapters/faraday"
    #   conn = Faraday.new("https://api.example.com") do |f|
    #     f.use Sashiko::Adapters::Faraday::Middleware
    #   end
    #
    # Attribute names follow OTel HTTP semantic conventions (stable).
    module Faraday
      class Middleware
        def initialize(app) = (@app = app)

        def call(env)
          method = env.method.to_s.upcase
          url    = env.url
          attrs = {
            "http.request.method" => method,
            "url.full"            => url.to_s,
            "server.address"      => url.host,
            "server.port"         => url.port,
          }

          Sashiko.tracer.in_span("HTTP #{method}", attributes: attrs, kind: :client) do |span|
            response = @app.call(env)
            span.set_attribute("http.response.status_code", response.status)

            case response.status
            in 100..399 # ok, no-op
            in Integer => code
              span.status = OpenTelemetry::Trace::Status.error("HTTP #{code}")
            end

            response
          rescue => e
            span.record_exception(e)
            span.status = OpenTelemetry::Trace::Status.error(e.message)
            raise
          end
        end
      end
    end
  end
end
