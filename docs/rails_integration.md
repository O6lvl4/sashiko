# Rails integration

Sashiko ships a small Rails companion module that fills gaps left by
the SIG-maintained `opentelemetry-instrumentation-rails`. Loaded
explicitly:

```ruby
require "sashiko/rails"
Sashiko::Rails.install!(notifications: /^my_app\./)
```

The pieces are independent — pick what you need, leave the rest.
None of them monkey-patch Rails internals.

## What's covered

| Helper | What it solves |
|---|---|
| `Sashiko::Rails.async(name) { ... }` | `Thread.new` from a controller drops OTel context → spawned spans become orphans. `Sashiko::Rails.async` runs the block in a Thread that preserves Context, wrapped in a span. |
| `Sashiko::Rails::TracedJob` | ActiveJob's serialize/deserialize cycle drops trace context across queue backends. Including this module rides the W3C Trace Context carrier as a serialized field on the job. Backend-agnostic — works against Sidekiq, GoodJob, SolidQueue, AsyncJob, the default `:test` adapter, etc. |
| `Sashiko::Rails.bridge_notifications(/regex/)` | `ActiveSupport::Notifications.instrument(...)` events emitted by your code aren't captured by SIG's instrumentation. The bridge subscribes to a pattern and emits one OTel span per matched event with the payload as attributes. |
| `Sashiko::Rails.install!(...)` | Top-level entry that delegates to the helpers above. Add this to a Rails initializer; expand as Sashiko grows new helpers. |

## Async work in controllers

```ruby
class OrdersController < ApplicationController
  def show
    threads = [
      Sashiko::Rails.async("orders.fetch_external") { ExternalAPI.fetch(@id) },
      Sashiko::Rails.async("orders.lookup_user")   { User.find(current_user.id) },
    ]
    @external, @user = threads.map(&:value)
  end
end
```

Each `async` block runs in its own Thread. The OTel context that was
current when `async` was called gets re-attached inside the spawned
thread, so the span produced by the block becomes a child of the
controller's request span instead of an orphan.

`async` accepts the same `tracer:` keyword as the rest of Sashiko —
useful inside a `Ruby::Box` where you want to route spans through a
box-local tracer.

## ActiveJob trace continuity

```ruby
# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  include Sashiko::Rails::TracedJob
end
```

Now every subclass picks up trace propagation automatically:

```ruby
class WelcomeEmailJob < ApplicationJob
  def perform(user_id)
    user = User.find(user_id)
    Sashiko::Rails.async("welcome.deliver") { Mailer.welcome(user).deliver_now }.join
  end
end

# Inside an HTTP request:
WelcomeEmailJob.perform_later(user.id)
```

What happens behind the scenes:

1. `serialize` (called as the job is enqueued) merges
   `Sashiko::Context.carrier.to_h` into the serialized job hash under
   the key `"_sashiko_trace_carrier"`.
2. The backend (Sidekiq / Solid Queue / whatever) ferries the
   serialized hash to a worker. The carrier is just a String→String
   Hash, so it survives JSON serialization.
3. `deserialize` extracts the carrier into an instance variable.
4. An `around_perform` callback attaches the carrier to the OTel
   Context before invoking `perform`. Spans inside `perform` become
   children of the trace that enqueued the job.

Empty carriers (job enqueued outside any active span) are tolerated:
the around_perform sees an empty hash and runs the perform without
attaching anything.

### Compatibility with SIG's `opentelemetry-instrumentation-active_job`

The two layers don't conflict. SIG's instrumentation produces a
`<job_class>.publish` / `<job_class>.process` span pair.
`Sashiko::Rails::TracedJob` rides the carrier *underneath* those spans
so user-code spans inside `perform` see the original request's trace.

## Bridging custom Notifications

If your app emits `ActiveSupport::Notifications.instrument(...)`
events that aren't covered by SIG instrumentation, the bridge turns
them into spans without re-instrumenting every call site:

```ruby
# Anywhere in your code:
ActiveSupport::Notifications.instrument("my_app.lookup", id: 42, kind: "user") do
  do_lookup(42)
end

# In an initializer:
Sashiko::Rails.bridge_notifications(/^my_app\./)
```

The bridge subscribes once and emits one span per event:
- Span name = event name (e.g. `"my_app.lookup"`)
- Span timestamps = event start / finish (so the span captures actual
  wall time, not the bridge handler time)
- Span attributes = payload hash with stringified keys; primitive
  values (String, Numeric, true/false/nil) pass through, others are
  `to_s`'d defensively.

Pass `tracer:` to route to a non-default tracer.

## What this does NOT do

- It does not auto-instrument controllers / views / SQL — that's
  what the SIG `opentelemetry-instrumentation-rails` gem is for.
  Use both together.
- It does not monkey-patch `Thread.new`. If you forget to use
  `Sashiko::Rails.async`, the standard library does what it always
  did. There's no surprise behavior process-wide.
- It does not depend on Rails — `lib/sashiko/rails.rb` only requires
  ActiveSupport / ActiveJob *at use time*, and only for the helpers
  that need them. `Sashiko::Rails.async` works without Rails loaded.

## Setup pattern

```ruby
# config/initializers/sashiko.rb

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my-rails-app"
  c.service_version = MyApp::VERSION
end

require "sashiko"
require "sashiko/rails"
Sashiko::Rails.install!(notifications: /^my_app\./)
```

Plus `include Sashiko::Rails::TracedJob` on your `ApplicationJob`
once. That's it.
