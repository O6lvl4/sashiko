# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project does not yet follow SemVer; the API is unstable until 1.0.

## [Unreleased]

### Changed
- `Sashiko::Box.new` now bootstraps Sashiko inside the Box. The previous
  `Sashiko::Box.new_with_sashiko` helper has been removed; for a bare
  `Ruby::Box` without Sashiko, use `::Ruby::Box.new` directly.
- README rewritten: marketing-tone phrasing removed, Quick Start moved
  to the top, and a Ractor span replay "Caveats" section added covering
  trace_id/span_id assignment, Baggage non-propagation, and replay-time
  sampling.
- Anthropic adapter: replaced four near-identical `case ... in ... else`
  stanzas in `record_response` and `set_usage_attributes` with single
  iteration over `RESPONSE_ATTRS` / `USAGE_ATTRS` lookup tables. Same
  semantics, fewer lines, no fallthrough holes.
- Ractor `Recorder` clock source: per-span timestamps now come from
  `CLOCK_MONOTONIC` offset against a single `CLOCK_REALTIME` anchor
  taken at recorder construction. OTel still gets wall-clock
  `start_timestamp` / `end_timestamp`, and durations no longer go
  negative if NTP adjusts the system clock mid-batch.
- `it` block parameter (Ruby 3.4+) used in tests and examples; `lib/`
  retains named block params for now because Steep 2.0 does not yet
  recognize `it` and would error during typecheck.
- Steep / RBS bumped to `>= 2.0` / `>= 4.0` (was `~> 1.9` / `~> 3.10`).
  Type-checking still clean.

### Documented (unchanged from earlier behavior)
- `Sashiko.tracer` is memoized to main's tracer on first call. Removing
  the memoization was attempted to make Box-internal calls "just work",
  but Ruby::Box does not isolate the `OpenTelemetry` module's state, so
  any in-Box `OpenTelemetry::SDK.configure` would also flip main's
  resolved tracer mid-process. The pitfall note in the Box section now
  spells this out: inside a Box, call
  `OpenTelemetry.tracer_provider.tracer(...)` directly.

### API consistency
- `Sashiko::Adapters::Anthropic.instrument!` now always returns the
  target class — including on subsequent (idempotent) calls. Previously
  re-invocation returned `nil`, which made chaining unsafe. The RBS
  signature is tightened from `Module?` to `Module`.
- `Sashiko::Adapters::Anthropic.instrument_in_box!` now raises
  `Sashiko::Box::NotEnabledError` instead of a generic `RuntimeError`
  when `RUBY_BOX=1` is not set. Both Box-related entry points share
  the same error class.

### Design notes
- `examples/poc/refinements_traced.rb` — runnable PoC evaluating
  whether Ruby refinements could replace the `Module#prepend`-based
  Traced DSL (and thus the need for Ruby::Box). Empirical result on
  Ruby 4.0.3: refinements pass `send`/`public_send` dispatch (S5) and
  subclass lookup (S4), but fail on internal `self`-calls inside a
  refined method (S3) and on external dispatchers like Sidekiq / web
  frameworks that don't `using` the refinement (S6). Refinements are
  call-site-scoped; Sashiko needs definition-site instrumentation.
  Decision: keep prepend + `tracer:` DI; do not adopt refinements.

### Repositioning
- README headline / lead changed from "Declarative OpenTelemetry
  instrumentation for Ruby 4" to **"Concurrency-boundary observability
  for Ruby on top of OpenTelemetry"**. The before/after snippet at the
  top now shows the actual problem (orphan spans across `Thread.new`)
  before any feature list. The Ruby 4 feature table is moved to an
  *Appendix: Ruby version targeting* at the end of the README — the
  4.0 capabilities (`Ractor::Port`, `Ruby::Box`) are described as
  "future-ready extras" rather than the headline.
- New demo `examples/thread_fanout_demo.rb` — runs the same
  `Controller#handle_request` with naive `Thread.new` and with
  `Sashiko::Context.parallel_map`, prints both trace trees so the
  reader sees orphan-vs-stitched in one shell command.
- `examples/README.md` updated with the new demo as the recommended
  starting point.
- The Anthropic adapter is now labeled "**optional, may move to a
  separate gem**" in its README section. The implementation, tests,
  and demos stay in this repo for now; any future extraction will be
  announced with a deprecation notice in this CHANGELOG.
- Sashiko continues to be positioned as a **companion** to the
  SIG-maintained `opentelemetry-instrumentation-*` gems, not a
  replacement.

### Polish sweep
- All `lib/` files now carry `# frozen_string_literal: true`.
- `Sashiko::Traced::Options` gains a `static_attrs` field. The frozen
  Hash holding `code.function` (and optionally `code.namespace`) is
  pre-baked at trace declaration time. `build_attributes` returns it
  directly when the call has no dynamic attributes, and otherwise
  starts from `static_attrs.dup`. Saves 2 String allocations and 1
  Hash construction per traced call.
- **Breaking (pre-1.0):** Faraday adapter span name changed from
  `"HTTP GET"` etc. to bare `"GET"` to match OTel HTTP semantic
  conventions (stable). Update existing dashboards / span filters.
- `sashiko.gemspec`: softened `summary` (removed "first-class"),
  added `description`, populated `metadata` with homepage / source /
  changelog / documentation / bug-tracker URIs and
  `rubygems_mfa_required = true`. `files` now ships RBS sigs +
  README.md + CHANGELOG.md.
- `examples/README.md`: ordered index of demos, with quick-reference
  shell commands.
- New regression tests in `test/regression_test.rb`:
  - `Sashiko.tracer` is memoized to the same object across calls.
  - `Sashiko::Box.new` outside `RUBY_BOX=1` raises `NotEnabledError`.
  - `trace :foo, tracer: alt` routes error spans to `alt`, not the
    default tracer.
  - Pre-baked `static_attrs` produces correct `code.*` attributes.

### Tracer DI (Box × OpenTelemetry escape hatch)

All public entry points that emit spans now accept an explicit `tracer:`
keyword. When set, it bypasses the memoized `Sashiko.tracer` and routes
spans through the given tracer instead. This is the recommended way to
keep instrumentation Box-local without fighting the global memoization:

- `Sashiko::Traced.trace(method, ..., tracer:)` — stored in the frozen
  `Options` Data record; resolved per-call as `options.tracer || Sashiko.tracer`.
- `Sashiko::Traced.trace_all(matching:, ..., tracer:)` — propagates to
  each generated `trace` call.
- `Sashiko::Ractor.parallel_map(items, via:, tracer:)` — passed through
  to `Sashiko::Ractor::Sink.replay(events, parent_carrier:, tracer:)`,
  resolved once on the main side so every replayed batch lands on the
  same provider.
- `Sashiko::Adapters::Faraday::Middleware.new(app, tracer:)` —
  `f.use Sashiko::Adapters::Faraday::Middleware, tracer: t`.
- `Sashiko::Adapters::Anthropic.instrument!(klass, tracer:)` — stored
  on the instrumented class; `Wrapper#create` reads it. Re-invocation
  rebinds the tracer without re-prepending.
- `Sashiko::Adapters::Anthropic.instrument_in_box!(box, name)` now
  binds the box-local tracer automatically (uses
  `OpenTelemetry.tracer_provider.tracer("sashiko/anthropic")`
  evaluated inside the box, falling back to `tracer: nil` if OTel
  isn't loaded inside the box yet).

The README "pitfall" note is updated to describe the DI escape hatch
instead of telling readers to drop down to raw OTel calls.

### Test coverage
- Faraday: added 5xx path (503 → `error.type = "503"` + ERROR status),
  explicit-tracer routing.
- Anthropic: added partial-keys, non-Hash `usage`, unknown model (no
  cost), idempotent `instrument!`, `NotEnabledError` raise path, and
  explicit-tracer routing.
- Traced: explicit-tracer routing.
- Ractor: explicit-tracer routing for replayed spans.

### Fixed
- `Sashiko::Ractor::Sink.replay` no longer raises `KeyError` when an
  event references a parent that was not part of the same replay batch.
  Orphaned events are now best-effort re-rooted under `parent_carrier`
  so the rest of the batch still emits.

### Added
- Faraday adapter now sets `error.type` on 4xx/5xx responses (numeric
  status as String) and on caught exceptions (exception class name),
  per current OTel HTTP semantic conventions.
- New tests:
  - Ractor: empty items, many-worker fan-out, worker raise aggregation,
    failed-worker still emits a span with error status, `Sink.replay`
    with empty events / orphaned parent.
  - Traced: `record_args` + `attributes` proc combined, `trace_all`
    skipping methods already directly traced, static-Hash `attributes:`.
  - Carrier: malformed `traceparent` does not crash and yields a fresh
    root span.
  - Faraday adapter: required HTTP semconv attributes, 4xx error.type,
    exception path.
- `DEFAULT_PRICING` carries an inline date stamp (2026-04 snapshot) and
  documents the override path; cost attribute is silently skipped for
  models not in the pricing Hash.
- `CHANGELOG.md` (this file).

### Notes
- Tests: 45 runs / 0 failures (default mode, 4 skips for `RUBY_BOX=1`
  gated tests). Under `RUBY_BOX=1`: 45 runs / 0 skips.
- Steep: 0 type errors.
