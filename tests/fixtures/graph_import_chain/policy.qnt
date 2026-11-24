module policy {
  /// Original transitive policy.
  pure def allowed(ok: bool): bool = ok
  pure val policyUse = allowed(true)
}

module alternatePolicy {
  /// Alternate transitive policy.
  pure def allowed(ok: bool): bool = not(ok)
  pure val alternateUse = allowed(false)
}
