// Neither module is named after the file.
module First {
  pure val same = "é😀" pure val other = 2
  pure val after = 4
}

module Second {
  pure def same(flag: bool): int = {
    val localValue = 3
    if (flag) localValue else 0
  }
  type Choice = | Some(int) | None
}
