# RubyKaigi CFP draft

Working draft for a Sashiko-based talk submission. Replace placeholders
when an actual CFP opens.

---

## Title

**Emitting OpenTelemetry spans from inside a Ractor (and other
concurrency-boundary problems in Ruby 4)**

Alternatives:

- "OpenTelemetry inside a Ractor"
- "What I learned building observability around Ruby 4's new
  concurrency primitives"
- "Stitching the trace: OpenTelemetry across Thread, Fiber, and
  Ractor in Ruby 4"

## Abstract (≤ 200 words)

OpenTelemetry's tracer relies on fiber-local context. Every time work
crosses a Thread, Fiber, queue, or Ractor boundary in a Ruby app, the
trace breaks: spans become orphans, distributed work loses parent
links, and Ractors crash with `IsolationError` if you even try to
emit a span. This talk walks through what actually happens at each
boundary in Ruby 4.0, and what it took to fix it for a small open
source library called Sashiko.

I'll cover three concrete sub-problems with live demos:

1. Why `Thread.new` orphans spans, and how a 60-line context
   propagation helper restores parent-child linkage.
2. Why `tracer.in_span` raises inside a Ractor (the OTel SDK's
   module state is unshareable), and how a *span replay* design —
   record events as frozen Data values inside the Ractor, ship them
   through `Ractor::Port`, re-emit them on the main side — produces
   a faithful trace tree from work that ran on separate cores.
3. How `Ruby::Box` interacts (and doesn't interact) with
   OpenTelemetry's module state, with a corrected diagnosis of an
   issue I shipped twice with two different explanations.

I'll also share refinement-based and DI-based alternatives I
evaluated, and benchmark numbers showing the DSL overhead is
sub-microsecond.

## Outline (3 bullets)

- **Problem walk** — 4 demos progressing from "vanilla OTel works"
  → "Thread orphans" → "Sashiko fixes Thread" → "Ractor literally
  raises IsolationError". This builds the audience's mental model
  of *why* the boundary is the unit of failure.
- **Span replay design** — the SpanEvent frozen Data shape, the
  Recorder's stack-based span tracking, the Sink's main-side
  replay with parent-chain reconstruction, the wall-clock /
  monotonic anchor for NTP-resilient durations, and the honest
  caveats (trace_id is replay-side, baggage is not propagated,
  sampling is replay-time).
- **Box × OTel × Refinements: what didn't work** — the
  `respond_to?(:tracer)` guard story, the `tracer:` DI escape
  hatch, why refinements can't replace `prepend` (with empirical
  PoC: passes 3 of 6 scenarios). What this means for "multi-tenant
  Ruby observability" as a problem space.

## Length / format

30 minutes is the natural fit. 50 minutes also works if expanding
the boundary walk to include Fiber and Sidekiq queue propagation,
plus a deeper dive into the `Ruby::Box` × `OpenTelemetry` interaction.

## Live demos

All demos are runnable via `bundle exec ruby examples/talk/<n>_*.rb`
and prepared as numbered files (~ 30 lines each, slide-friendly):

1. `01_baseline.rb` — sequential vanilla OTel
2. `02_thread_orphans.rb` — Thread.new drops context (orphans)
3. `03_thread_stitched.rb` — `Sashiko::Context.parallel_map` fixes it
4. `04_ractor_isolation_error.rb` — vanilla OTel raises in Ractor
5. `05_ractor_span_replay.rb` — Sashiko's solution: trace tree
6. `06_box_otel_pollution.rb` — `Sashiko.tracer` × Box, corrected diagnosis
7. `07_tracer_di.rb` — DI escape hatch routing two services to two providers

Backup if live demos go sideways: each demo's expected output is in
the file's docstring.

## Empirical claims I'll make on stage

(All measured on Ruby 4.0.3, ARM64, 2026-04 — see
[`docs/benchmarks.md`](benchmarks.md).)

- `Sashiko::Traced` adds **~290 ns / call** vs raw `tracer.in_span`.
  With per-call attribute Procs, ~940 ns. Sub-microsecond either way.
- `Sashiko::Ractor.parallel_map` delivers **3.07× speedup** on a
  CPU-bound prime sieve workload (8 items, 8 cores), with full span
  tree preserved.
- `Sink.replay` runs at **~4.3 μs / event**, flat across 10 to 1000
  event batches. Replay cost is dominated by `tracer.start_span`
  itself, not by Sashiko's bookkeeping.

## Why this matters for the Ruby community

Ruby 4.0 finally shipped Ractor::Port and Ruby::Box — the two big
concurrency-related additions in years. Both are flagged
experimental, and both interact with existing libraries in
non-obvious ways. Observability is one of the first places those
interactions show up, because OTel needs to work *across* every
concurrency primitive a Ruby app uses. Reporting concretely on what
breaks (and what doesn't) helps both library authors planning
Ractor support and Ruby committers prioritizing experimental-flag
removal.

## Speaker bio (placeholder)

[fill in for actual submission]

## Companion artifacts

- Sashiko gem: <https://github.com/O6lvl4/sashiko>
- Companion docs:
  [`ractor_span_replay.md`](ractor_span_replay.md),
  [`box_otel_interaction.md`](box_otel_interaction.md),
  [`refinements_evaluated.md`](refinements_evaluated.md)
- Benchmarks: [`benchmarks.md`](benchmarks.md)
- Talk demos: [`examples/talk/`](../examples/talk/)
