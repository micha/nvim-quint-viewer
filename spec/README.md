# Viewer specification roadmap

The viewer has two independently verified workflows for `review` from
[the approval example](../examples/approval.qnt): [offline Definition links](source_navigation.qnt)
and [definition jumps from a read-only source graph](graph_navigation.qnt).
For both, a thin interpreter drives the public plugin commands and keymaps
and records observations. Quint judges those observations against the same
transition rules that produced the histories.

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
the named histories in both models and checks each emits a trace. TLC
explores 19 reachable states for offline navigation and 14 for the source
graph. These checks verify the models, not the plugin implementation.
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
cursor, without opening a split.

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
cursor, notices, and outgoing definition requests. It waits for the server's
parse/analysis publications before testing navigation, and waits for any
requests sent to complete. [The Python driver](../tests/replay_graph_navigation.py)
feeds the observations back to Quint. Two negative controls keep the other
observations fixed: report a wrong return cursor, or report one request from
a stale graph. Both must be rejected during testing.
