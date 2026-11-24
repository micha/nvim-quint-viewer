module caller {
  import policy as remote from "./policy"
  pure def allowed(ok: bool): bool = not(ok)

  pure def review(input: bool): bool = {
    val permitted = input
    if (remote::allowed(permitted)) allowed(permitted) else false
  }
}
