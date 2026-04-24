require_relative "lib/sashiko/version"

Gem::Specification.new do |spec|
  spec.name     = "sashiko"
  spec.version  = Sashiko::VERSION
  spec.authors  = ["sashiko contributors"]
  spec.summary  = "Declarative OpenTelemetry instrumentation for Ruby, with first-class concurrency context propagation."
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "opentelemetry-api", "~> 1.4"
  spec.add_dependency "opentelemetry-sdk", "~> 1.5"
  spec.add_dependency "opentelemetry-semantic_conventions", "~> 1.10"
end
