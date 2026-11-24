module policy {
  pure def allowed(ok: bool): bool = helper(ok)
  pure def helper(ok: bool): bool = ok
}
