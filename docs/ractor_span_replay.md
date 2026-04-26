# Ractor span replay — design walkthrough

This document explains how Sashiko emits OpenTelemetry spans from work
that ran inside a Ractor, given that vanilla OTel Ruby cannot. It is
the long-form companion to
[`examples/talk/04_ractor_isolation_error.rb`](../examples/talk/04_ractor_isolation_error.rb)
and [`examples/talk/05_ractor_span_replay.rb`](../examples/talk/05_ractor_span_replay.rb).

## The wall

OpenTelemetry Ruby's SDK keeps state on module-level instance
variables: a mutex, a propagation registry, processor lists. None of
these are Ractor-shareable. So the moment a Ractor reaches for
`OpenTelemetry.tracer_provider`, Ruby raises:

```
Ractor::IsolationError: can not get unshareable values from instance
variables of classes/modules from non-main Ractors
(@mutex from OpenTelemetry)
```

The OTel Ruby SIG has acknowledged this as a blocker for Ractor
adoption; there is no near-term fix on either side.

## The idea

OTel Spans are mostly *data*: a name, a kind, an attributes map, a
start/end timestamp, an optional parent id, an optional error string.
The act of *emitting* a span is what the SDK refuses to do across
Ractors — but recording the *data* of one is just struct construction,
which is fine.

So Sashiko separates the two:

```
worker Ractor:                main Ractor:
  ┌──────────────────────┐      ┌──────────────────────┐
  │ Sashiko::Ractor.span │ ───► │ Sashiko::Ractor::Sink│
  │   ─ records frozen   │      │   ─ replays each     │
  │     SpanEvent values │      │     SpanEvent as a   │
  │   ─ ships them via   │      │     real OTel span   │
  │     Ractor::Port     │      │     with original    │
  └──────────────────────┘      │     timestamps + ids │
                                └──────────────────────┘
```

A diagram view is in
[`docs/assets/ractor_span_replay.svg`](assets/ractor_span_replay.svg).

## The data shape

```ruby
SpanEvent = Data.define(
  :id,            # monotonically incrementing per Ractor
  :parent_id,     # nil for the root, otherwise a previous event's id
  :name,
  :kind,          # :internal, :client, :server, ...
  :attributes,    # frozen Hash<String, primitive>
  :start_ns,      # Integer nanoseconds (anchored — see below)
  :end_ns,
  :status_error,  # nil or the exception's message
)
```

`Data.define` makes this frozen and Ractor-shareable by default. No
references to OTel objects appear anywhere on the worker side.

## Recording (worker side)

Each Ractor opens with a `Recorder` thread-local. The recorder maintains
a stack of currently-open span ids and produces SpanEvents on close:

```ruby
class Recorder
  def initialize
    @events      = []
    @stack       = []
    @next_id     = 0
    @wall_anchor = Process.clock_gettime(Process::CLOCK_REALTIME,  :nanosecond)
    @mono_anchor = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  end

  def span(name, kind: :internal, attributes: nil)
    id = (@next_id += 1)
    parent_id = @stack.last
    start_ns = now_ns
    @stack.push(id)
    begin
      yield
    ensure
      @events << SpanEvent.new(
        id:, parent_id:, name:, kind:,
        attributes: deep_freeze(attributes || {}),
        start_ns:, end_ns: now_ns,
        status_error: $!&.message,
      )
      @stack.pop
    end
  end

  private

  # Wall-clock anchor + monotonic offset. OTel wants wall-clock
  # timestamps; monotonic offset keeps spans immune to NTP jumps
  # mid-batch.
  def now_ns
    @wall_anchor + (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - @mono_anchor)
  end
end
```

When the worker finishes, `drain_events!` returns a deeply frozen
array of SpanEvents that crosses the Port boundary safely.

## Replaying (main side)

```ruby
def Sink.replay(events, parent_carrier:, tracer:)
  parent_ctx = OpenTelemetry.propagation.extract(parent_carrier)
  replayed   = {}

  events.sort_by(&:id).each do |event|
    ctx = if event.parent_id.nil?
            parent_ctx
          elsif (parent = replayed[event.parent_id])
            OpenTelemetry::Trace.context_with_span(parent)
          else
            parent_ctx  # orphaned event: re-root rather than crash
          end

    OpenTelemetry::Context.with_current(ctx) do
      span = tracer.start_span(
        event.name,
        kind: event.kind,
        attributes: event.attributes,
        start_timestamp: Time.at(0, event.start_ns, :nanosecond),
      )
      span.status = OpenTelemetry::Trace::Status.error(event.status_error) if event.status_error
      span.finish(end_timestamp: Time.at(0, event.end_ns, :nanosecond))
      replayed[event.id] = span
    end
  end
end
```

The `parent_carrier` (W3C Trace Context headers) is captured *before*
spawning the Ractors via `Sashiko::Context.carrier`. Replayed spans
attach to whatever main-side span wrapped `parallel_map`.

## What replay preserves and what it doesn't

Preserved:
- Span name, kind, attributes (frozen at record time)
- Start / end timestamps (wall-clock)
- Parent linkage *within the batch*
- Attachment to the main-side parent context

Not preserved:
- `trace_id` and `span_id` are assigned at replay time on the main
  side. The Ractor never sees a real `SpanContext`.
- `OpenTelemetry::Baggage` set inside the Ractor is NOT propagated
  out — only what was in `Sashiko::Context.carrier` when
  `parallel_map` was called.
- Sampling is decided at replay time on main, not when the work
  actually ran.

These are honest tradeoffs: the trace consumer sees a faithful tree,
but the spans were *constructed* on the main side, not "transmitted"
from the workers in the OTel SDK sense.

## Failure modes

Three corner cases are covered by tests
([`test/ractor_test.rb`](../test/ractor_test.rb)):

1. **Worker raises** — the SpanEvent is still emitted with
   `status_error` set, so the failed step shows up in the trace tree
   with an ERROR status. `parallel_map` aggregates all worker errors
   and re-raises after replay completes.
2. **Empty items / single-worker** — degenerate cases return without
   work.
3. **Orphan event** — a SpanEvent whose `parent_id` doesn't exist in
   the replay batch (e.g. partial drain) is re-rooted under
   `parent_carrier` rather than raising `KeyError`.

## When to use it

`Sashiko::Ractor.parallel_map` is for genuinely CPU-bound work that
benefits from real multi-core parallelism. For I/O-bound fan-out from
inside a request handler, prefer `Sashiko::Context.parallel_map`
(thread-based) — Threads share Ractor's safety constraints without
the SpanEvent ceremony.
