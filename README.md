# Sashiko

> **Your Sidekiq workers and parallel threads should live in the same trace as the request that started them.** Sashiko makes that happen.

Declarative OpenTelemetry instrumentation for Ruby 4, with first-class
cross-boundary trace context propagation.

Named after *sashiko* (刺し子), a Japanese stitching technique that
reinforces fabric with small, deliberate stitches — the same way this
gem weaves small, deliberate spans into the fabric of your code.

📖 **API docs**: <https://o6lvl4.github.io/sashiko/>

---

## The problem

Plain OpenTelemetry Ruby drops trace context the moment work crosses a
boundary:

```
Without Sashiko:                 With Sashiko:

[trace A]                         [trace A]
└─ POST /orders                   └─ POST /orders
                                     └─ OrderWorker#perform
[trace B]   ← disconnected 😢        └─ HTTP POST warehouse.com
└─ OrderWorker#perform               └─ HTTP POST email.com
   └─ HTTP POST warehouse.com
```

Because `OpenTelemetry::Context` lives in fiber-local storage:

- A span started inside `Thread.new { ... }` becomes a **new root span**.
- A Sidekiq job has no link to the web request that enqueued it.
- Wrapping every method in `tracer.in_span("...") do ... end` is
  verbose and bleeds observability into business logic.

Sashiko fixes these three problems with three small APIs.

## Built for Ruby 4

Sashiko is designed from the ground up with Ruby 4's modern toolbox.
Each idiom is used where it improves the code, not for showmanship.

| Ruby 4-era feature | Where it's used in Sashiko |
|---|---|
| `Data.define` (immutable values) | `Sashiko::Traced::Options`, `Sashiko::Adapters::Anthropic::Price` — frozen, typed, Ractor-shareable by default |
| Pattern matching (`in` / deconstruct) | Attribute extraction in `Traced`, response parsing in the Anthropic adapter, HTTP status classification in the Faraday adapter |
| Endless methods (`def foo = …`) | Public accessors and one-line delegates throughout |
| `it` default block parameter | Filter/reject chains in `trace_all` |
| `Ractor.make_shareable` | `Sashiko::Context.carrier` returns a deep-frozen, Ractor-shareable Hash — one of the few things you can cleanly hand to a Ractor |
| RBS signatures | Ship `sig/sashiko.rbs` for Steep users |
| Frozen-by-default `Data` + shareable config | Zero mutable global state in adapters; pricing tables are frozen and shareable |

Example: look at how attribute sources are resolved in
`Sashiko::Traced` — one pattern-match replaces the traditional
`respond_to?` chain:

```ruby
extra = case options.attributes
        in Proc => fn then fn.arity.zero? ? fn.call : fn.call(*args, **kwargs)
        in Hash => h  then h
        else nil
        end
```

Or the Faraday adapter classifying HTTP status codes:

```ruby
case response.status
in 100..399     # ok, no-op
in Integer => code
  span.status = OpenTelemetry::Trace::Status.error("HTTP #{code}")
end
```

## Quick start

```ruby
# Gemfile
gem "sashiko", github: "O6lvl4/sashiko"
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
```

```ruby
# config/initializers/otel.rb
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

OpenTelemetry::SDK.configure { it.service_name = "my-app" }

require "sashiko"
```

```ruby
class OrderService
  extend Sashiko::Traced

  trace :checkout, attributes: ->(order) { { "order.id" => order.id } }
  def checkout(order)
    charge(order)
    notify(order)
  end

  trace :charge
  trace :notify
  def charge(order); ...; end
  def notify(order); ...; end
end
```

Every call to `checkout` now produces a span named `OrderService#checkout`,
with `charge` and `notify` as children. Exceptions are recorded and the
span is marked as errored automatically.

## Core API

### `Sashiko::Traced` — declarative spans

```ruby
class Svc
  extend Sashiko::Traced

  # Wrap a single method.
  trace :work, attributes: ->(x) { { "work.id" => x.id } }

  # Wrap every method matching a pattern (declare AFTER the defs).
  trace_all matching: /^handle_/
end
```

`trace` options:
- `name:` — override the span name (defaults to `ClassName#method`).
- `kind:` — `:internal` (default), `:client`, `:server`, etc.
- `attributes:` — a `Proc` receiving the call arguments, or a static
  `Hash`. Pattern-matched against `Proc` / `Hash` shapes internally.
- `record_args: true` — include arg count as `code.args.count`.

### `Sashiko::Context` — propagation across Thread / Fiber

```ruby
# Thread.new that preserves the current OTel Context.
Sashiko::Context.thread { do_work }.join

# Fiber.new likewise.
Sashiko::Context.fiber { do_work }.resume

# Fan-out helper: one thread per item, all with the captured Context,
# results returned in input order.
results = Sashiko::Context.parallel_map(jobs) { |j| process(j) }
```

Without these helpers, plain `Thread.new` drops the OTel Context and
your spans become orphans. Sashiko makes the connection explicit.

### Carrier-based propagation — across processes, queues, Ractors

The same primitive works for any boundary where you can pass strings:

```ruby
# Producer side: capture current trace context as a serializable Hash.
queue.push(
  payload: "...",
  trace_context: Sashiko::Context.carrier,
)

# Worker side: re-attach it before doing traced work.
job = queue.pop
Sashiko::Context.attach(job[:trace_context]) do
  process(job)
end
```

`carrier` is a deep-frozen `Ractor`-shareable hash of W3C Trace Context
headers (`traceparent`, `tracestate`). It survives JSON serialization,
Sidekiq job args, Kafka message attributes, HTTP headers, **and
`Ractor.new(...)` arguments**. The worker's spans end up in the same
distributed trace as the producer's.

## Adapters (optional)

Adapters are not loaded by default — require them explicitly. Adapters
are intentionally thin; the core gem has zero vendor-specific code.

### Faraday

```ruby
require "sashiko/adapters/faraday"

conn = Faraday.new("https://api.example.com") do |f|
  f.use Sashiko::Adapters::Faraday::Middleware
end
```

Produces client-kind spans named `HTTP GET` / `HTTP POST` etc., with
HTTP semantic convention attributes.

### Anthropic

```ruby
require "sashiko/adapters/anthropic"

Sashiko::Adapters::Anthropic.instrument!(Anthropic::Messages)
```

Produces GenAI-semantic-convention spans on every `messages.create` call,
including token counts, cache hit ratio, and estimated USD cost. Pricing
is stored as a frozen `Data.define(Price)` value; override via
`Sashiko::Adapters::Anthropic.pricing =`.

> The Anthropic adapter is intentionally thin. Model names, pricing,
> and the GenAI spec are still moving targets — treat this adapter as
> a convenience, not a stable contract.

## A note on Ractors

Ruby 4's headline feature is Ractor becoming more viable. Sashiko
cooperates as far as it can:

- `Sashiko::Context.carrier` returns a `Ractor.make_shareable`-d Hash,
  so you can hand it to `Ractor.new(...)` directly.
- `Data`-based config (Options, Price) is Ractor-shareable.
- `DEFAULT_PRICING` is deep-frozen via `Ractor.make_shareable`.

What is **not** currently possible: emitting spans from inside a
Ractor. This is blocked upstream — `OpenTelemetry` and
`OpenTelemetry.propagation` carry unshareable instance variables
(mutexes, provider references) that a non-main Ractor cannot reach.
For now, use Ractors for CPU-parallel compute and emit spans on the
main Ractor after collecting results.

## Types

`sig/sashiko.rbs` ships with the gem. If you use Steep:

```yaml
# Steepfile
target :lib do
  check "lib"
  signature "sig"
  library "opentelemetry-sdk"
end
```

## Examples

- [`examples/demo.rb`](examples/demo.rb) — parallel jobs with preserved
  parent-child span links across threads.
- [`examples/queue_demo.rb`](examples/queue_demo.rb) — producer enqueues
  jobs; workers on the other side continue the same distributed trace.

```sh
bundle install
bundle exec ruby examples/demo.rb
bundle exec ruby examples/queue_demo.rb
```

## Development

```sh
bundle install
bundle exec rake test    # run tests
bundle exec rake docs    # generate RDoc to doc/
```

## Requirements

- Ruby 4.0 or later
- `opentelemetry-api` `~> 1.4`
- `opentelemetry-sdk` `~> 1.5`

## Status

Early. API may change. 18 tests, all passing.

## License

MIT.
