module caller {
  import wrapper as remote from "./wrapper"
  /// Local policy.
  pure def allowed(ok: bool): bool = not(ok)
  pure def review(ok: bool): bool =
    if (remote::allowed(ok)) allowed(ok) else false
  pure val again = remote::allowed(true)
}
