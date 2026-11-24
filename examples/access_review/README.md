# Access review

With the [Quint language server configured](../../README.md#view-a-saved-quint-file),
open `examples/access_review/access_review.qnt` and run `:QuintView review`.
Leave `policy.qnt` unopened to try a jump into a file you haven't visited yet.

- Press `gd` on `org::allowed` in `eligible = …` to open its graph from
  `policy.qnt`. `Ctrl-O` returns to that exact occurrence; `Ctrl-I` goes forward.
- Press `gd` on bare `allowed` in the outer `No` branch to open the graph of
  the same-named *local* definition. Use `gD` instead to jump to editable source.
- On `eligible` in `IF eligible`, press `K` to see its `bool` type, or `grr`
  to list the declaration and the guard reference. Use `:lclose` to close
  the list. Both lookups also work on the imported call.
- Press `za` on the outer `Yes` or `No` heading to fold or unfold that branch,
  including its nested decision. The other branch stays as it was.

To try the stale-graph warning, make an unsaved edit to `access_review.qnt`
from another window while the graph is open. Back in the graph, `gd` on
`org::allowed` warns and stays put. Or edit only `policy.qnt`: the imported
jump is blocked, but the local `allowed` jump still works. Save or reload the
affected files, then build a fresh graph with `:QuintView review` from
`access_review.qnt`. If the server still returns the old destination, run
`:lsp restart quint` from `access_review.qnt` and try again.
