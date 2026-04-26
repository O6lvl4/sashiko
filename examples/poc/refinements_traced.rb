# PoC: can Ruby refinements replace Sashiko's prepend-based DSL?
#
# Question: instead of `extend Sashiko::Traced; trace :method` (which
# globally wraps the method via Module#prepend), can we use refinements
# so that each "tenant" gets its own wrapped view of the same class —
# without Ruby::Box?
#
# This PoC builds a tiny refinement-based tracer and runs it through 5
# scenarios that any production instrumentation must handle. Each
# scenario prints PASS / FAIL with a one-line explanation.
#
# Run:  ruby examples/poc/refinements_traced.rb

# ----- Tiny in-memory span recorder (no OTel dep) ----------------------

module SpanLog
  @spans = []
  class << self
    attr_reader :spans
    def record(name, tenant)
      @spans << [name, tenant]
    end
    def reset = @spans.clear
    def names_for(tenant) = @spans.select { it[1] == tenant }.map { it[0] }
  end
end

# ----- The class we want to instrument ---------------------------------

class OrderService
  def checkout(order)
    charge(order)
    "checked out: #{order}"
  end

  def charge(order) = "charged: #{order}"
end

class PremiumOrderService < OrderService
  # Inherits checkout from parent.
end

# ----- Tenant-A's refinement-based tracer ------------------------------

module TenantATrace
  refine OrderService do
    def checkout(order)
      SpanLog.record("OrderService#checkout", :tenant_a)
      super
    end

    def charge(order)
      SpanLog.record("OrderService#charge", :tenant_a)
      super
    end
  end
end

# ----- Tenant-B's refinement-based tracer (different attributes) -------

module TenantBTrace
  refine OrderService do
    def checkout(order)
      SpanLog.record("OrderService#checkout[B]", :tenant_b)
      super
    end
  end
end

# ----- Helpers ---------------------------------------------------------

def assert(name, cond, detail)
  status = cond ? "PASS" : "FAIL"
  puts "[#{status}] #{name}  — #{detail}"
end

puts "=" * 70
puts "Refinements PoC — can refinements replace Sashiko's prepend DSL?"
puts "=" * 70

# ----- Scenario 1: same class, two callers, two tenants ----------------

module TenantACaller
  using TenantATrace
  def self.run(svc, order) = svc.checkout(order)
end

module TenantBCaller
  using TenantBTrace
  def self.run(svc, order) = svc.checkout(order)
end

SpanLog.reset
svc = OrderService.new
TenantACaller.run(svc, "o1")
TenantBCaller.run(svc, "o2")

assert(
  "S1: per-caller tenant isolation",
  SpanLog.names_for(:tenant_a) == ["OrderService#checkout", "OrderService#charge"] &&
    SpanLog.names_for(:tenant_b) == ["OrderService#checkout[B]"],
  "Each tenant sees its own spans for its own caller. (#{SpanLog.spans.length} spans recorded)"
)

# ----- Scenario 2: caller without `using` sees no instrumentation ------

module UnrefinedCaller
  def self.run(svc, order) = svc.checkout(order)
end

SpanLog.reset
UnrefinedCaller.run(svc, "o3")

assert(
  "S2: unrefined caller is untouched",
  SpanLog.spans.empty?,
  "Code that doesn't `using` a refinement runs the original — good for isolation, bad for global instrumentation."
)

# ----- Scenario 3: nested call from inside the refined method ----------
# Inside OrderService#checkout (refined), it calls self.charge. Does the
# inner call also see the refinement?

SpanLog.reset
TenantACaller.run(svc, "o4")

# The PASS criteria: both checkout AND charge were recorded — meaning
# the refinement DID activate for the in-method call to `charge`.
assert(
  "S3: nested call inside refined method sees refinement",
  SpanLog.names_for(:tenant_a).include?("OrderService#charge"),
  "Refinements activate based on the call's lexical scope. The call to `charge` happens inside OrderService's source file (where no `using` is in scope), so refinements DO NOT activate. Sashiko's prepend-based DSL DOES catch this case."
)

# ----- Scenario 4: subclass dispatch -----------------------------------
# PremiumOrderService inherits checkout from OrderService. Does the
# refinement on OrderService apply when calling `.checkout` on a subclass
# instance from inside `using TenantATrace`?

SpanLog.reset
premium = PremiumOrderService.new
TenantACaller.run(premium, "o5")

assert(
  "S4: subclass dispatch through refinement",
  SpanLog.names_for(:tenant_a).include?("OrderService#checkout"),
  "Refinement on OrderService catches PremiumOrderService instances when method is inherited. (Ruby's refinement lookup walks the ancestry.)"
)

# ----- Scenario 5: send / public_send dispatch -------------------------

module SendDispatchCaller
  using TenantATrace
  def self.run(svc, order) = svc.send(:checkout, order)
end

SpanLog.reset
SendDispatchCaller.run(svc, "o6")

assert(
  "S5: dispatch via `send` reaches refinement",
  SpanLog.names_for(:tenant_a).include?("OrderService#checkout"),
  "Many frameworks dispatch user code through `send`/`public_send`. If refinements don't catch this, instrumentation is invisible to those entry points."
)

# ----- Scenario 6: external library callsite (mocked Sidekiq job) ------
# Mock a "Sidekiq job runner" that's defined in another file/library and
# does NOT include our `using`. This is the realistic production case:
# you can't sprinkle `using` into every framework that dispatches your code.

class FakeJobRunner
  # Defined "outside" the tenant's source tree. No `using`.
  def perform(svc, order) = svc.checkout(order)
end

SpanLog.reset
FakeJobRunner.new.perform(svc, "o7")

assert(
  "S6: external dispatcher (no `using`) sees instrumentation",
  !SpanLog.spans.empty?,
  "Realistic production case: a job runner / framework / RSpec test invokes user code without `using`. Spans don't fire — instrumentation invisible to the dispatcher."
)

# ----- Verdict ---------------------------------------------------------

puts
puts "=" * 70
puts "Verdict"
puts "=" * 70
puts <<~VERDICT

  Refinements solve a different problem than Sashiko's prepend DSL:

    Refinements activate at the CALL site (lexically scoped).
    Prepend activates at the DEFINITION site (globally scoped).

  Empirical results from this PoC on Ruby 4.0.3:

    PASS — S2: unrefined callers see no spans (good isolation).
    PASS — S4: subclass dispatch resolves to the parent's refinement.
    PASS — S5: send / public_send DOES go through refinements
                (this is better than feared; older Ruby versions
                behaved differently).

    FAIL — S1: per-caller isolation surface-level works, but only
                because S3 also fails — total span count is short
                by exactly the spans S3 misses.
    FAIL — S3: a refined method that calls another method on `self`
                does NOT see its own refinement for the inner call.
                Sashiko's prepend DSL catches this case naturally.
    FAIL — S6: any external dispatcher (Sidekiq job runner, web
                framework, RSpec) that invokes user code without
                `using` produces zero instrumentation. This is the
                production-realistic case, and it's a hard fail.

  Conclusion: refinements cannot replace Sashiko's prepend-based DSL.
  Sashiko's value is "instrument once, observe everywhere"; refinements
  give "instrument lexically, observe only inside the lexical region".
  Different products.

  Refinements would also not eliminate Ruby::Box: Box gives
  definition-site isolation, refinements give call-site opt-in.
  Orthogonal mechanisms.

  Recommended path forward: keep the prepend-based DSL with `tracer:`
  DI as the documented escape hatch for Box-local isolation. The DI
  approach works at definition time and survives external dispatchers,
  which is precisely what refinements cannot do.

VERDICT
