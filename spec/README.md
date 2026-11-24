# Viewer specification roadmap

The viewer has verified models for [source graph selection](graph_selection.qnt),
[definition jumps from a read-only source graph](graph_navigation.qnt),
[native branch folding](branch_folding.qnt),
[hover and references from the source graph](graph_lookups.qnt), and
[cross-file definition jumps](graph_import.qnt). A thin interpreter
drives public commands and keys and records observations. Quint judges those
observations against the same transition rules that produced the histories.

## Source graph selection

From a saved `.qnt` file, `:QuintView` without arguments opens the top-level
operator or value at the cursor in a read-only graph in the same window.
The [selection fixture](../tests/fixtures/graph_selection.qnt) exercises two
definitions on one line after a Unicode string, same-named definitions in two
modules, and a cursor on a local binding inside the selected definition. A
cursor outside a definition, including on a type variant, emits one error and
leaves the source and cursor in place.

The named form uses the module at the cursor and shows the requested names
in order. Outside a module it falls back to the only local module, or the
one matching the filename. If neither rule selects a module, or if a name
is not defined in the selected module, the command does not switch buffers.

The retired `*.qmodel.json` entry point is modeled separately: opening a
valid old export leaves ordinary JSON in the existing window. Each history
covers one command from a clean session, without a language server.

## Verify and generate histories

From the checkout, run:

```sh
nix develop .#spec -c scripts/check-spec.sh
```

The separate shell supplies Quint 0.33.1, Java, and the pinned Apalache
0.62.4 distribution that Quint uses for TLC. The script runs `quint verify`
with TLC over the complete finite model (no trace-length cap), then runs
the named histories in each model and checks each emits a trace. TLC
explores 16 reachable states for selection, 27 for source graph navigation,
103 for branch folding, 14 for graph hover and references, and 39 for
cross-file definition navigation.
These checks verify the models, not the plugin implementation.
Quint can reuse an already-running Apalache server; to use the pinned
version, leave port 8822 free or set `QMODEL_SPEC_ENDPOINT` to another unused
local endpoint (for example, `127.0.0.1:8823`).

To inspect the generated histories, run:

```sh
traces=$(mktemp -d)
nix develop -c quint test spec/graph_selection.qnt --backend=typescript \
  --seed=1 --out-itf="$traces/{test}_{seq}.itf.json"
```

Each ITF state contains `session.request` (`op` and `arg`) and an expected
`session.view`. The initial `init` row describes the baseline. Keep generated
traces untracked.

## Replay against Neovim

`scripts/check.sh` runs replay after checking graph export. To replay only
selection, use:

```sh
nix develop -c python3 -B tests/replay_graph_selection.py --worktree
```

Omit `--worktree` to test a fresh installation from committed `HEAD`.
[The Python driver](../tests/replay_graph_selection.py) gives only requests
from the ITF histories to [the Lua interpreter](../tests/replay_graph_selection.lua).
Each history starts a clean headless Neovim session. Quint executes the same
transitions and checks the observed view after each request. The selection
negative control substitutes the real graph for the wrong definition on the
same line; Quint must reject it through the same assertions. Java and TLC
are needed for model verification, not for replay.

## Source graph navigation

Open the saved approval source and run `:QuintView review`. The command
replaces the window's view with a read-only graph; it leaves source editable.
On `allowed` in the `IF allowed` row, `gd` asks the attached Quint language
server for the definition and lands on its name (line 9, byte column 8,
counting columns from zero). `Ctrl-O` restores the exact graph buffer and
cursor, without opening a split. With default Neovim fold options, `Yes`
stays closed and `No` stays open if the jump started with `Yes` folded.

An unsaved edit or a disk edit after graph generation leaves the old graph
readable. `gd` stays at the occurrence and emits one warning, without sending
an LSP definition request. The disk-edit history then reloads the source,
regenerates the graph, and checks that `gd` now lands one line lower and
`Ctrl-O` returns to the new graph. The model covers a single window, one
source file and definition, and at most one edit. It assumes a ready server;
requests in flight while files change and other LSP actions are outside the
slice. [Imported definitions](#cross-file-definition-navigation) have their own model.

### Replay the source graph

The replay uses the real upstream stdio server, not a stub. The tested pair
is Quint CLI `0.34.0` and `quint-language-server` `0.21.0`. With Node.js and
npm, you can put that pair on `PATH` without installing them globally:

```sh
lsp_tools=$(mktemp -d)
npm install --prefix "$lsp_tools" --no-save --no-package-lock \
  @informalsystems/quint@0.34.0 @informalsystems/quint-language-server@0.21.0 lodash
nix develop -c sh -c \
  'export PATH="$1/node_modules/.bin:$PATH"; shift; exec scripts/check.sh "$@"' \
  sh "$lsp_tools" --worktree --with-lsp
```

The explicit `lodash` install works around an undeclared server dependency.
Omit `--worktree` to test an installation from committed `HEAD`. For just
this replay, run `python3 -B tests/replay_graph_navigation.py --worktree`
with the same tools on `PATH`.

[The Lua interpreter](../tests/replay_graph_navigation.lua) observes actual
window count, focus, source coordinates, modifiability, the exact graph
cursor, visible closed branches, notices, and outgoing definition requests.
It waits for the server's parse/analysis publications before testing navigation, and waits for any
requests sent to complete. [The Python driver](../tests/replay_graph_navigation.py)
feeds the observations back to Quint. Two negative controls keep the other
observations fixed: report a wrong return cursor, or report one request from
a stale graph. Both must be rejected during testing.

## Cross-file definition navigation

[The model](graph_import.qnt) exercises `gd` on two separate calls in the
[import fixture](../tests/fixtures/graph_import): `remote::allowed` lands on
the definition line in `policy.qnt`, and bare `allowed` lands on the local
definition in `caller.qnt`. Neither opens a split, and `Ctrl-O` restores the
original graph buffer and exact cursor in the same window. A dirty caller,
a dirty imported buffer, or an on-disk edit to the imported definition file
makes the affected jump warn once without sending a request. Editing the
import does not block the local jump.

On rebuild after an on-disk move, the graph knows the new declaration line,
but the server can still reply with the old location. This reply warns and
leaves focus on the graph. Restarting the server from the caller and rebuilding
the graph recovers the jump to the new line and the exact `Ctrl-O` return.

TLC checks all 39 reachable states without a trace-length bound. The replay
starts with the imported file unopened and checks the exact fixture file path
and declaration line, leaving the imported destination column to the server.
It covers one direct import and either an unsaved edit or a disk move; changes
while requests are in flight, exact imported columns, and transitive import
invalidation are outside this slice. The controls substitute the actual
same-named local landing, change only the destination file, or replace only
the moved declaration line with its old line. Quint must reject each through
the normal replay assertions.

With the tools above, run `scripts/check.sh --worktree --with-lsp` or just
`python3 -B tests/replay_graph_import.py --worktree`.

## Graph hover and references

From `IF allowed` in `:QuintView review`, `K` asks the server about the
condition occurrence, not the declaration. It displays `val allowed: bool`
in a native floating preview without moving focus or the graph cursor.
`grr` asks about the same occurrence, includes the declaration, and focuses
an ordinary location list owned by the graph window. The graph stays at the
original cursor. Both keys do nothing on an unlinked heading. If the graph
is stale from an unsaved edit or a change on disk, each key warns once and
sends no request.

[The model](graph_lookups.qnt) covers one lookup per history, one ready
server, and a single source file; concurrent requests, unsupported methods,
and navigation within a returned list are outside this slice. The replay
observes the actual outbound LSP parameters, preview, location list, focus,
cursor, and notices. The negative controls report a lookup at the declaration
instead of the occurrence, a request despite a stale warning, and a missing
reference. Quint must reject each through the same assertion path.

Run `scripts/check.sh --worktree --with-lsp` with the tools above, or run just
this replay with `python3 -B tests/replay_graph_lookups.py --worktree`.

## Native branch folding

In `:QuintView`, explicit `if`/`else` branches start expanded. A `Yes` or `No`
heading is the first line of its fold. Closing a branch hides its body but
keeps the heading visible. Siblings fold independently; opening a parent
restores the previous open or closed state of its children.

[The model](branch_folding.qnt) covers a graph with an inner decision in the
outer `Yes` branch and a single-line outer `No` body. It exercises `zc` on open
headings, `zo` on closed headings, and `za` on either. A separate deep graph
checks that the level-20 fold includes its entire subtree even when some
branches exceed Neovim's native nesting limit. Counts, other native fold
commands, multiple windows, and non-default fold policies are outside the model.

`scripts/check.sh` replays the histories without an LSP server. The
[interpreter](../tests/replay_branch_folding.lua) presses the native keys and
observes the closed ranges and their displayed headings. The negative control
reports a real view with both outer branches closed where only `Yes` should
have closed. Quint must reject it. To run just this replay against local edits:

```sh
nix develop -c python3 -B tests/replay_branch_folding.py --worktree
```
