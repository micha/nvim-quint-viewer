# Access review

With the [Quint language server configured](../../README.md#view-a-saved-quint-file),
open `examples/access_review/access_review.qnt` and run `:QuintView review`.
Leave `policy.qnt` unopened to try a jump into a file you haven't visited yet.

- Press `gd` on `org::allowed` in `eligible = …`. It opens the definition
  in `policy.qnt`. Press `Ctrl-O` to return to the same graph occurrence.
- Press `gd` on bare `allowed` in the outer `No` branch. It opens the
  same-named *local* definition in `access_review.qnt`. Use `Ctrl-O` again.
- On `eligible` in `IF eligible`, press `K` to see its `bool` type, or `grr`
  to list the declaration and the guard reference. Use `:lclose` to close
  the list. Hover and references don't yet work on the imported link.
- Press `za` on the outer `Yes` or `No` heading to fold or unfold that branch,
  including its nested decision. The other branch stays as it was.

To try the stale-graph warning, make an unsaved edit to `access_review.qnt`
from another window while the graph is open. Back in the graph, `gd` on
`org::allowed` warns and stays put. Undo or save the edit, then build a fresh
view with `:QuintView review` from the source window.
