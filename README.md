# nvim-quint-viewer

Read a [Quint](https://quint.sh/) definition as a decision tree in Neovim.
From a `.qnt` file, open a read-only graph in the same window and navigate
back to ordinary source with the Quint language server. You can also open a
standalone export offline with its symbol inspector. Both are views of the
rules as written, not a simulation, proof, or map of reachable states.

## Install

Requires Neovim 0.12 or newer and Git. Add this to `init.lua`:

```lua
vim.pack.add({ 'https://github.com/micha/nvim-quint-viewer' })
```

Or install from a local Git checkout (use its absolute path):

```lua
vim.pack.add({ 'file:///absolute/path/to/nvim-quint-viewer' })
```

Choose one source. `vim.pack` clones the checkout; use `:packupdate` after
committing local changes. For live plugin development instead of a managed
install, prepend the checkout to `runtimepath`.

## View a saved Quint file

Put Python 3.10+ and `quint` on `PATH`. For definition jumps, install
[`quint-language-server`](https://www.npmjs.com/package/@informalsystems/quint-language-server)
and configure Neovim to attach it to Quint source buffers, if it doesn't
already. If server `0.21.0` fails with `Cannot find module 'lodash'`, install
`lodash` into the same npm prefix as the server.

For example, in `init.lua`:

```lua
vim.filetype.add({ extension = { qnt = 'quint' } })
vim.lsp.config('quint', {
  cmd = { 'quint-language-server', '--stdio' },
  filetypes = { 'quint' },
  root_markers = { '.git' },
})
vim.lsp.enable('quint')
```

Open `examples/approval.qnt` and run `:QuintView review`. Put the cursor on
`allowed` in `IF allowed` and press `gd` to jump to its definition. `Ctrl-O`
returns to the graph at the original cursor position. The graph is read-only;
the real `.qnt` buffer is unchanged and still editable. If source changes,
the old graph stays readable but refuses new definition lookups. Save or reload
the source, then run `:QuintView review` again from it.

Explicit `if`/`else` branches start expanded. On a `Yes` or `No` heading,
press `za` to toggle that branch, `zc` to close it, or `zo` to open it. A closed
branch keeps its heading visible. Independent folds are limited to 20 levels
by Neovim; deeper branches stay inside their ancestor’s fold. Native options
like `foldlevelstart` still apply on later buffer entry. Other expressions
are shown as source.

`:QuintView` selects the module named after the file. `gd` works on underlined,
indexed references in that module when a single definition-capable LSP client
is attached. Graph hover, references, and import navigation are not implemented
yet. This route does not use DML presentation rules.

## Try an offline export

From a checkout of this repo, use Python 3 and Quint 0.33.1 on `PATH`, or prefix
the export command with `nix develop -c`:

```sh
mkdir -p build
python3 tools/export_model.py examples/approval.qnt review -o build/approval.qmodel.json
nvim build/approval.qmodel.json
```

The viewer recognizes `*.qmodel.json` exports automatically; no extra setup
is needed. Opening an export does not run Quint, Python, or an LSP server.
The export contains a path relative to the artifact and a source checksum;
keep the source in place for jumps, and regenerate the export after editing it.

- Put the cursor on `allowed` and press **Enter** to inspect it.
- Use `]s` and `[s` to move between symbols. Use `<C-w>l` to enter the inspector
  (or `<C-w>j` if Neovim puts it below the graph).
- Press **Enter** on an inspector entry to jump to its occurrence in the graph
  or open its source line in another split. `q` closes the focused viewer pane.

## Export your own model

Pass the definition names you want to review, in display order. The exporter
visualizes `if`/`else` at the decision-tree level and shows other expressions as
source text. Select a module with `--module` if it differs from the filename.
References are indexed within that module; imported definitions and record
types other than `State` do not yet get full navigation.

For the [DML](https://github.com/micha/dml) refs model, the optional profile
expands the `Prediction` outcomes and shows the state fields each branch sets:

```sh
python3 tools/export_model.py ../dml/tests/ref_rules.qnt editRef finishTxn \
  --profile dml-refs -o build/ref.qmodel.json
```

## Develop

New features and observable behavior changes follow the
[Quint-first workflow](AGENTS.md#quint-first-development): verify the design
before implementing it, then replay Quint histories against headless Neovim.
See the [specification roadmap](spec/README.md) for the navigation and folding
models. Run `nix develop .#spec -c scripts/check-spec.sh` to verify them
independently of the plugin.

`nix develop -c scripts/check.sh` checks deterministic export, artifact
selection, and navigation, then replays offline navigation and native source
folds against a clean plugin installation from the committed `HEAD`. Pass
`--worktree` to test uncommitted changes. To also replay graph navigation with
the real server, add `--with-lsp` with a compatible Quint CLI and server on
`PATH`; see [the replay instructions](spec/README.md#replay-the-source-graph).
