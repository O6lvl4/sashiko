# Ruby::Box × OpenTelemetry — interaction notes

This document explains a non-obvious aspect of using Sashiko inside
`Ruby::Box`, including a corrected diagnosis of the original problem.
It is the long-form companion to
[`examples/talk/06_box_otel_pollution.rb`](../examples/talk/06_box_otel_pollution.rb).

## Initial (incorrect) diagnosis

When `RUBY_BOX=1` tests were run after removing the memoization on
`Sashiko.tracer`, several main-process tests failed with empty
exporters. Our first hypothesis was that `Ruby::Box` does *not* isolate
the top-level `OpenTelemetry` module's instance state — i.e. that
`OpenTelemetry::SDK.configure` from inside a Box would also overwrite
main's `OpenTelemetry.tracer_provider`.

That was wrong.

## The reproducer

[`examples/talk/06_box_otel_pollution.rb`](../examples/talk/06_box_otel_pollution.rb)
captures the `object_id` of `OpenTelemetry.tracer_provider` in main
before and after a Box runs `SDK.configure`, and also captures the
in-Box `object_id`. Output:

```
main's tracer_provider before box: object_id=1120
main's tracer_provider after  box: object_id=1120
box's tracer_provider:             object_id=1216

→ main's tracer_provider unchanged: true
→ box has its own provider:         true
```

So `Ruby::Box` **does** isolate `OpenTelemetry.tracer_provider`. Each
Box has its own. Main's stays exactly as it was.

## The actual mechanism

Sashiko is a shared module — `Ruby::Box` shares top-level constants
with main, but each Box has its own `$LOADED_FEATURES`, so a `require
"sashiko"` inside a Box re-evaluates `lib/sashiko.rb`.

`lib/sashiko.rb` defines `Sashiko.tracer` like this:

```ruby
unless respond_to?(:tracer)
  class << self
    def tracer = @tracer ||= OpenTelemetry.tracer_provider.tracer(...)
  end
end
```

The `unless respond_to?(:tracer)` guard is doing work. Without it, the
Box's re-evaluation would re-run `class << self; def tracer; ... end`,
and the new method body's *constant resolution scope* would be the
Box's. Because `Sashiko` itself is shared across main and the Box, the
re-bound method would surface in main too — so main's `Sashiko.tracer`
would suddenly be looking up `OpenTelemetry` against the Box's
namespace, breaking main's tests.

With the guard, redefinition is skipped inside the Box. The method
stays bound to main's `OpenTelemetry`. The price: `Sashiko.tracer`
called from inside a Box still returns *main's* tracer, not the Box's.
Spans go to main's pipeline.

Demo 06's last assertion confirms this:

```
spans in main's exporter: ["from_inside_box"]
```

The Box ran `Sashiko.tracer.in_span("from_inside_box") { }`, and the
span landed in *main's* exporter — even though the Box has its own
`tracer_provider` and its own SDK configured.

## The escape hatch

To emit Box-local spans through Sashiko's DSL, pass an explicit
`tracer:` evaluated inside the Box:

```ruby
box.eval(<<~RUBY)
  require "opentelemetry/sdk"
  OpenTelemetry::SDK.configure { |c| ... }

  klass = Object.const_get("MyService")

  # `tracer:` is captured at trace time, evaluated inside the Box,
  # so it resolves to the Box's tracer_provider.
  klass.singleton_class.send(:include, Sashiko::Traced)
  klass.trace :work, tracer: OpenTelemetry.tracer_provider.tracer("svc")
RUBY
```

`Sashiko::Adapters::Anthropic.instrument_in_box!` does this binding
automatically:

```ruby
box.eval(<<~RUBY)
  require "sashiko/adapters/anthropic"
  klass = Object.const_get(#{messages_class_name.inspect})
  local_tracer = defined?(::OpenTelemetry) ?
    ::OpenTelemetry.tracer_provider.tracer("sashiko/anthropic") : nil
  Sashiko::Adapters::Anthropic.instrument!(klass, tracer: local_tracer)
RUBY
```

## When this actually matters

This nuance only shows up if you both (a) instrument inside a
`Ruby::Box` and (b) want spans to land on the Box's pipeline rather
than main's. For most users, leaving `Sashiko.tracer` alone — letting
all Sashiko calls land on main — is the right answer.

## Further reading

- [Misc #21681: Roadmap of Ruby Box for 4.0](https://bugs.ruby-lang.org/issues/21681)
- [Bug #21760: Ruby::Box require-related problems](https://bugs.ruby-lang.org/issues/21760)
- [Bug #22015: bundler/inline fails under RUBY_BOX=1](https://bugs.ruby-lang.org/issues/22015)
