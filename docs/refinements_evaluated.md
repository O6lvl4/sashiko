# Refinements as a Sashiko alternative — evaluated

This document captures the design evaluation for: *could Ruby
refinements replace `Module#prepend` as Sashiko's instrumentation
mechanism?* The runnable PoC is in
[`examples/poc/refinements_traced.rb`](../examples/poc/refinements_traced.rb).

## Why this question came up

Sashiko's `Module#prepend`-based DSL produces process-global
instrumentation. To get per-tenant isolation, we use `Ruby::Box`. But
`Ruby::Box` is experimental and has known constraints (native
extensions, `bundler/inline`, parts of `active_support` don't work
inside one).

If refinements could give us the same end state — "this caller sees
instrumented `OrderService`, that caller sees the original" — without
needing Box, we could collapse two mechanisms into one and drop the
Box dependency entirely.

## Test scenarios

The PoC defines two `using`-able refinement modules (`TenantATrace`,
`TenantBTrace`) that each refine `OrderService#checkout` with span
recording. Six scenarios are exercised:

| # | Scenario | Result |
|---|---|---|
| S1 | per-caller tenant isolation | **FAIL** — total spans short by exactly the count S3 misses |
| S2 | unrefined caller sees no spans | PASS |
| S3 | self-call inside refined method sees its own refinement | **FAIL** |
| S4 | subclass dispatch through refinement | PASS |
| S5 | dispatch via `send` / `public_send` reaches refinement | PASS |
| S6 | external dispatcher (no `using`) sees instrumentation | **FAIL** |

## What each result means

**PASS S2** — refinements scope correctly to lexical regions. Code
that doesn't `using` the refinement runs the original method. Good
isolation, but flip-side: any code path you forget to update is silent.

**PASS S4** — refinement on `OrderService` is also active when
`checkout` is invoked on `PremiumOrderService` (subclass that inherits
the method). Ruby's refinement lookup walks the ancestry.

**PASS S5** — surprisingly, `send`/`public_send` does activate the
refinement on Ruby 4.0.3. Earlier Ruby versions had inconsistent
behavior here; current Ruby is consistent. Frameworks that dispatch
user code via `send` (Rails routing, RSpec matchers, etc.) would still
see refined methods *if* the dispatching code itself is inside a
`using` block.

**FAIL S3** — the most interesting failure. Inside `OrderService#checkout`'s
body, calling `self.charge(order)` does NOT activate the refinement
that wraps `charge`. Refinements activate based on the *call site's*
lexical scope — and the call site here is in `OrderService.rb`, which
has no `using`. Sashiko's prepend DSL catches this case naturally
because prepend rewrites the method lookup chain globally.

**FAIL S6** — the production-realistic failure. A `FakeJobRunner`
class defined "elsewhere" (i.e. without `using`) calls `svc.checkout`.
Spans don't fire. Real-world equivalents: Sidekiq job runners, web
framework dispatchers, RSpec test bodies — none of them `using` your
refinement, none of them produce spans.

**FAIL S1** — looks like S1 should pass given S2/S4/S5 do, but the
total span count is short. The reason is S3: `checkout` is refined,
but `charge` (called from inside `checkout`) is not, because the
inner call site is unrefined. So tenant A sees `["checkout"]` instead
of `["checkout", "charge"]`.

## Conclusion

Refinements activate at the **call site** (lexical scope). Sashiko's
prepend-based DSL activates at the **definition site** (global). These
are different products, not interchangeable mechanisms.

Concretely, swapping prepend for refinements would:

- Lose all instrumentation when frameworks dispatch user code (S6).
- Lose instrumentation for self-calls inside the same class (S3).
- Force every caller to opt in via `using` (S2 — feature, not bug,
  but at this point you've fragmented the contract).

It would also not eliminate `Ruby::Box`: Box gives definition-site
isolation, refinements give call-site opt-in. They address different
isolation needs.

## Decision

Sashiko keeps its prepend-based DSL. The `tracer:` DI keyword
documented in the README remains the recommended path for per-tenant
or per-Box isolation.

The PoC stays in the repo as `examples/poc/refinements_traced.rb` so
this evaluation is reproducible. If a future Ruby version changes
refinement semantics in any of the FAIL scenarios above, this question
is worth revisiting.
