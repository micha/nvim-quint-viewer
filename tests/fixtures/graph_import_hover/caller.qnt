module caller {
  import policy as remote from "./policy"
  /// Local check.
  pure def allowed(ok: bool): bool = not(ok)

  pure def review(ok: bool): bool =
    if (remote::allowed(ok)) allowed(ok) else false
}
