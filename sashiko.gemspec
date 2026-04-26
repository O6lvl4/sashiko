# frozen_string_literal: true

require_relative "lib/sashiko/version"

Gem::Specification.new do |spec|
  spec.name     = "sashiko"
  spec.version  = Sashiko::VERSION
  spec.authors  = ["sashiko contributors"]
  spec.summary  = "Declarative OpenTelemetry instrumentation for Ruby, with concurrency context propagation across Thread, Fiber, and Ractor boundaries."
  spec.description = <<~DESC
    Sashiko is a small Ruby gem that adds a declarative span DSL on top of
    OpenTelemetry, plus helpers for keeping trace context attached as work
    crosses Thread, Fiber, queue, HTTP, and Ractor boundaries. Includes a
    span-replay mechanism for emitting spans from Ractor workers, optional
    Faraday and Anthropic adapters, RBS signatures, and a Ruby::Box-aware
    `tracer:` injection path for multi-tenant observability.
  DESC
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb"] + Dir["sig/**/*.rbs"] + ["README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.homepage = "https://github.com/O6lvl4/sashiko"
  spec.metadata = {
    "source_code_uri"   => "https://github.com/O6lvl4/sashiko",
    "changelog_uri"     => "https://github.com/O6lvl4/sashiko/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://o6lvl4.github.io/sashiko/",
    "bug_tracker_uri"   => "https://github.com/O6lvl4/sashiko/issues",
    "rubygems_mfa_required" => "true",
  }

  spec.add_dependency "opentelemetry-api", "~> 1.4"
  spec.add_dependency "opentelemetry-sdk", "~> 1.5"
  spec.add_dependency "opentelemetry-semantic_conventions", "~> 1.10"
end
