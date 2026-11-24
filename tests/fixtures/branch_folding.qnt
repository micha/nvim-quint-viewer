module branch_folding {
  pure def decide(outer: bool, inner: bool): int =
    if (outer) {
      if (inner) 10 else 20
    } else 30
}
