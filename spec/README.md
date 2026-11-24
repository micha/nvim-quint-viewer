# Viewer specification roadmap

The viewer has verified models for [offline Definition links](source_navigation.qnt),
[definition jumps from a read-only source graph](graph_navigation.qnt),
[native branch folding](branch_folding.qnt), and
[hover and references from the source graph](graph_lookups.qnt). A thin interpreter
drives public commands and keys and records observations. Quint judges those
observations against the same transition rules that produced the histories.

## Source navigation

The model starts with a fresh export and no viewer open. It opens the export,
selects one of two symbols in the graph, focuses the inspector, and follows
that symbol's **Definition** link (not its selected occurrence link). The
source file may change on disk after opening the viewer and before the jump.

- A fresh jump adds one source pane, retains the graph and inspector, and
  focuses the source at the selected definition's line and column zero.
- A changed source adds no pane, keeps focus in the inspector, and emits one
  warning about the changed fingerprint. The edit itself does not notify.

The model is limited to one clean session, two definitions, one optional
on-disk edit to a still-readable source, and one link attempt. Terminal states
can stutter. It does not model missing files, unsaved buffers, repeated jumps,
changes during a jump, pane layout, other links, or invalid exports.

## Verify and generate histories

From the checkout, run:

```sh
nix develop .#spec -c scripts/check-spec.sh
```

The separate shell supplies Quint 0.33.1, Java, and the pinned Apalache
0.62.4 distribution that Quint uses for TLC. The script runs `quint verify`
with TLC over the complete finite model (no trace-length cap), then runs
the named histories in each model and checks each emits a trace. TLC
explores 19 reachable states for offline navigation, 27 for source graph
navigation, 103 for branch folding, and 14 for graph hover and references.
These checks verify the models, not the plugin implementation.
Quint can reuse an already-running Apalache server; to use the pinned
version, leave port 8822 free or set `QMODEL_SPEC_ENDPOINT` to another unused
local endpoint (for example, `127.0.0.1:8823`).

To inspect the generated histories, run:

```sh
traces=$(mktemp -d)
nix develop -c quint test spec/source_navigation.qnt --backend=typescript \
  --seed=1 --out-itf="$traces/{test}_{seq}.itf.json"
```

Each ITF state contains `session.request` (`op` and `arg`), the source-change
input, and an expected `session.view`. The initial `init` row describes the
baseline before user actions. The `approval.qnt` destination is an ID for the
exact resolved fixture path, not a basename match. `selected` is a scoped
fixture symbol name, not an exporter-generated ID. Pane roles are sorted and
retain duplicates; notices report severity and reason from that request, not
text already visible in the inspector. Keep generated traces untracked.

## Replay against Neovim

`scripts/check.sh` runs replay after the exporter and viewer smoke tests. To
run only replay, use:

```sh
nix develop -c python3 -B tests/replay_source_navigation.py --worktree
```

Omit `--worktree` to test a fresh installation from committed `HEAD`.
[The Python driver](../tests/replay_source_navigation.py) gives only requests
from the ITF histories to [the Lua interpreter](../tests/replay_source_navigation.lua).
Each history uses a fresh fixture export and a clean headless Neovim session.
The driver feeds the observed view after each request back to Quint, which
executes the same transitions and checks each view. It also keeps the real
stale warning but substitutes the pane, focus, and cursor changes from a
fresh jump. Quint must reject that negative control through the same
assertions. Java and TLC are needed for model verification, not for replay.

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
requests in flight while files change, imported definitions, and other LSP
actions are outside the slice.

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
