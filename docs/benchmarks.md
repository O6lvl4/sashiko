# Benchmarks

Numbers below were taken on Ruby 4.0.3, Apple Silicon (M-series),
2026-04. Run the scripts yourself to verify on your hardware.

## DSL overhead — `tracer.in_span` vs `Sashiko::Traced`

What it measures: per-call overhead of three styles of OTel
instrumentation, all producing the same span shape (name, kind,
attributes). Workload is a 2x integer multiply.

```
$ bundle exec ruby bench/traced_overhead.rb
ruby 4.0.3 (2026-04-21 revision 85ddef263a) +PRISM [arm64-darwin24]
Calculating -------------------------------------
tracer.in_span (raw)              281.7k i/s   (3.55 μs/call)
Sashiko::Traced (static attrs)    260.1k i/s   (3.84 μs/call)
Sashiko::Traced + Proc attrs      222.9k i/s   (4.49 μs/call)

Comparison:
  Sashiko::Traced (static):  1.08x slower than raw  (~0.29 μs overhead)
  Sashiko::Traced (proc):    1.26x slower than raw  (~0.94 μs overhead)
```

Reading: the declarative DSL adds **~290 nanoseconds** per traced
call vs. a hand-written `tracer.in_span` block. With a per-call
attributes Proc, the overhead grows to ~940 nanoseconds — entirely
attributable to invoking the Proc and merging its result Hash.

Both numbers are well under 1 microsecond and dominated by the OTel
SDK's own span construction cost (3.55 μs of the 3.84 μs / 4.49 μs).
For real workloads (HTTP calls, DB queries, LLM invocations measured
in milliseconds), the DSL overhead is unobservable.

The "static attrs" path is the fast path: Sashiko pre-bakes
`code.function` / `code.namespace` into a frozen Hash at trace
declaration time, returning it directly to OTel without per-call
allocation.

Bench source: [`bench/traced_overhead.rb`](../bench/traced_overhead.rb).

## Ractor parallel throughput

What it measures: wall-clock time to run 8 prime-sieve jobs over
varying upper bounds, sequentially vs across `Ractor::Port`-backed
parallel Ractors. Includes span emission for every step.

```
$ bundle exec ruby bench/ractor_replay_throughput.rb
Items per batch: 8 ([3000, 5000, 7000, 9000, 11000, 13000, 15000, 17000])
Iterations:      5

  sequential:                  0.403 s  ( 80.6 ms/batch)
  Sashiko::Ractor.parallel:    0.131 s  ( 26.3 ms/batch)
  speedup:                    3.07x
```

Reading: at 8 items on an 8-performance-core M-series chip,
`Sashiko::Ractor.parallel_map` delivers a **3.07× speedup** over
sequential execution despite shipping SpanEvents back through
`Ractor::Port` and replaying them on the main side. Speedup is
bounded by core count and Port overhead; 2–4× is typical.

The trace produced is identical in shape to a sequential run — the
parent / child structure is preserved by the replay mechanism.

Bench source: [`bench/ractor_replay_throughput.rb`](../bench/ractor_replay_throughput.rb).

## Sink replay cost

What it measures: main-side cost of `Sink.replay` translating
pre-recorded SpanEvents into real OTel spans, isolated from the
Ractor execution itself.

```
$ bundle exec ruby bench/sink_replay_cost.rb
    11 events × 1000 iter →  0.051 s  (4.65 μs/event)
   101 events × 1000 iter →  0.430 s  (4.26 μs/event)
  1001 events × 1000 iter →  4.352 s  (4.35 μs/event)
```

Reading: `Sink.replay` runs at roughly **4.3 microseconds per event**,
flat across batch sizes from 11 to 1001 events. So replaying a
1000-event Ractor batch back to the main thread costs about 4 ms —
negligible relative to the actual CPU work the Ractors are doing.

The cost is dominated by `tracer.start_span` itself, not by the
replay bookkeeping. Sashiko's parent-id resolution + frozen-event
iteration adds essentially nothing on top.

Bench source: [`bench/sink_replay_cost.rb`](../bench/sink_replay_cost.rb).

## Summary

| Metric | Result |
|---|---|
| Sashiko::Traced static-attrs overhead vs raw `in_span` | **~290 ns** (1.08×) |
| Sashiko::Traced proc-attrs overhead vs raw `in_span` | **~940 ns** (1.26×) |
| Ractor parallel speedup (8 items, 8 cores) | **3.07×** |
| `Sink.replay` per-event cost | **~4.3 μs** |

For talk-friendly takeaways:

- The declarative DSL is **functionally free** vs hand-rolled OTel
  blocks (sub-microsecond overhead per call).
- Ractor span replay **is not a tax** — multi-core wins are real
  (3× on this workload) and the replay step adds milliseconds, not
  whole percentage points.
