# Examples

Each demo is self-contained — `bundle install` once, then run any of the
files below. They progress from "smallest possible Sashiko program" to
the multi-tenant case.

## Core

- [`demo.rb`](demo.rb) — three jobs run in parallel threads under a
  shared `JobRunner#run` parent span. Demonstrates `Sashiko::Traced` +
  `Sashiko::Context.parallel_map` keeping parent-child links across
  threads. *Start here.*
- [`queue_demo.rb`](queue_demo.rb) — a producer enqueues work with
  `Sashiko::Context.carrier`; a worker on the other side calls
  `Sashiko::Context.attach` and continues the same distributed trace.
  Shows the cross-process / cross-queue propagation primitive.

## Ractor

- [`ractor_demo.rb`](ractor_demo.rb) — `Ractor::Port` powering true
  CPU-parallel work under a single traced batch span. The simplest
  shape; no in-Ractor span recording, only a parent span on the main
  side and computed results coming back.
- [`ractor_span_replay_demo.rb`](ractor_span_replay_demo.rb) — each
  Ractor records its own nested spans via `Sashiko::Ractor.span`; the
  main side replays them as a unified trace tree printed in ASCII.

## Real-world adapter

- [`real_api_demo.rb`](real_api_demo.rb) — Faraday adapter against a
  live HTTP endpoint. Exercises the client-span attribute set
  (`http.request.method`, `url.full`, `server.*`,
  `http.response.status_code`, `error.type`).

## Multi-tenant

- [`box_multitenant_demo.rb`](box_multitenant_demo.rb) — two tenants
  sharing one Ruby process, each with its own Sashiko, OpenTelemetry
  SDK, and exporter. Requires `RUBY_BOX=1` (Ruby::Box is experimental
  in 4.0).

## PoC / design notes

- [`poc/refinements_traced.rb`](poc/refinements_traced.rb) —
  empirical evaluation of whether Ruby refinements could replace
  Sashiko's `Module#prepend`-based DSL. Conclusion: no, and the file
  documents why with 6 numbered scenarios and PASS / FAIL output. See
  [`docs/refinements_evaluated.md`](../docs/refinements_evaluated.md)
  for the long-form write-up.

## Talk arc — slide-friendly demo sequence

Numbered scripts under [`talk/`](talk/) progressing from "vanilla OTel
works" to "Ractor needs span replay". Each is < 50 lines so a single
file fits on a slide.

1. [`talk/01_baseline.rb`](talk/01_baseline.rb) — sequential, no boundary, vanilla OTel works.
2. [`talk/02_thread_orphans.rb`](talk/02_thread_orphans.rb) — `Thread.new` produces orphan spans.
3. [`talk/03_thread_stitched.rb`](talk/03_thread_stitched.rb) — `Sashiko::Context.parallel_map` keeps the trace stitched.
4. [`talk/04_ractor_isolation_error.rb`](talk/04_ractor_isolation_error.rb) — vanilla OTel raises `Ractor::IsolationError` inside a Ractor.
5. [`talk/05_ractor_span_replay.rb`](talk/05_ractor_span_replay.rb) — Sashiko's solution: SpanEvent record + main-side replay.
6. [`talk/06_box_otel_pollution.rb`](talk/06_box_otel_pollution.rb) — `Sashiko.tracer` × `Ruby::Box`. Requires `RUBY_BOX=1`.
7. [`talk/07_tracer_di.rb`](talk/07_tracer_di.rb) — DI escape hatch routing two services to two providers.

## Quick reference

```sh
bundle install

# Core
bundle exec ruby examples/demo.rb
bundle exec ruby examples/queue_demo.rb

# Ractor
bundle exec ruby examples/ractor_demo.rb
bundle exec ruby examples/ractor_span_replay_demo.rb

# Real API
bundle exec ruby examples/real_api_demo.rb

# Multi-tenant (requires Ruby::Box)
RUBY_BOX=1 bundle exec ruby examples/box_multitenant_demo.rb

# Design PoC (no OTel dep, prints PASS/FAIL + verdict)
ruby examples/poc/refinements_traced.rb
```
