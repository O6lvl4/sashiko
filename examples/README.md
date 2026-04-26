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
  `CHANGELOG.md` "Design notes" for the summary.

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
