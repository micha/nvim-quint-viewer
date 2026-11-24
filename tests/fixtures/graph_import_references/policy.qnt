module policy {
  pure def allowed(ok: bool): bool = ok
  pure val policyUse = allowed(true)
}
