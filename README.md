# Sashiko

Declarative OpenTelemetry instrumentation for Ruby, with first-class
cross-boundary trace context propagation.

Named after *sashiko* (刺し子), a Japanese stitching technique that
reinforces fabric with small, deliberate stitches — the same way this
gem inserts small, deliberate spans into the fabric of your code.

## Why this exists

OpenTelemetry's Ruby Context lives in fiber-local storage. That means:

- A span started inside `Thread.new { ... }` silently becomes a **root
  span**, losing its parent. Your Sidekiq workers, thread pools, and
  parallel HTTP calls end up as disconnected traces.
- A job dequeued by a worker has no automatic link to the web request
  that enqueued it. You see the producer trace and the consumer trace
  as two separate things.
- Wrapping methods in `tracer.in_span("...") do ... end` blocks is
  verbose, repetitive, and bleeds observability concerns into business
  logic.

Sashiko fixes these three problems with three small APIs.

## Quick start

```ruby
require "sashiko"

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

  # Wrap every method matching a pattern (must be declared after the defs).
  trace_all matching: /^handle_/
end
```

### `Sashiko::Context` — propagation across Thread / Fiber

```ruby
# Thread.new that preserves the current OTel Context.
Sashiko::Context.thread { do_work }

# Fiber.new likewise.
Sashiko::Context.fiber { do_work }

# Fan-out helper: runs each block on its own thread, all with the
# captured Context, returning results in input order.
Sashiko::Context.parallel_map(jobs) { |j| process(j) }
```

Without these helpers, a plain `Thread.new` drops the OTel Context and
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

`carrier` is just a hash of W3C Trace Context headers (`traceparent`,
`tracestate`). It survives JSON serialization, Sidekiq job args, Kafka
message attributes, HTTP headers, and Ractor.new arguments. The worker's
spans end up in the **same distributed trace** as the producer's.

## Adapters (optional)

Adapters are not loaded by default — require them explicitly.

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
including token counts, cache hit ratio, and estimated USD cost.

> The Anthropic adapter is intentionally thin. Model names, pricing, and
> the GenAI spec are still moving targets — treat this adapter as a
> convenience, not a stable contract.

## Examples

- [`examples/demo.rb`](examples/demo.rb) — parallel jobs with preserved
  parent-child span links.
- [`examples/queue_demo.rb`](examples/queue_demo.rb) — producer enqueues
  jobs; workers on the other side continue the same distributed trace.

```sh
bundle install
bundle exec ruby examples/demo.rb
bundle exec ruby examples/queue_demo.rb
```

## Requirements

- Ruby 4.0 or later
- `opentelemetry-api` `~> 1.4`
- `opentelemetry-sdk` `~> 1.5`

## Status

Early. API may change. 17 tests, all passing.

## License

MIT.
