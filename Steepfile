target :lib do
  signature "sig"
  check "lib"

  library "pathname", "logger", "json"

  # Steep's understanding of `extend SomeModule` DSL patterns is limited —
  # it can't tell that `self` inside an extended method refers to the
  # extending class. Downgrade those specific diagnostics to warnings so
  # `steep check` doesn't fail on a known-incomplete aspect of the
  # signature, while still flagging them for visibility.
  configure_code_diagnostics do |hash|
    hash[Steep::Diagnostic::Ruby::NoMethod]                  = :warning
    hash[Steep::Diagnostic::Ruby::ArgumentTypeMismatch]      = :warning
    hash[Steep::Diagnostic::Ruby::UndeclaredMethodDefinition] = :information
  end
end
