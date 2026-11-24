# nvim-quint-viewer

Read a [Quint](https://quint.sh/) definition as a decision tree in Neovim. The
left pane shows the conditions, Yes/No branches, and outcomes. The inspector
shows a symbol’s definition, type, incoming references (**Used by**), and
outgoing references (**Depends on** and **Writes**). This is a view of the rules
as written, not a simulation, proof, or map of reachable states.

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

## Try the example

From a checkout of this repo, use Python 3 and Quint 0.33.1 on `PATH`, or prefix
the export command with `nix develop -c`:

```sh
mkdir -p build
python3 tools/export_model.py examples/approval.qnt review -o build/approval.qmodel.json
nvim build/approval.qmodel.json
```

The viewer opens only `*.qmodel.json` files; no extra setup is needed. Opening an
export does not run Quint, Python, or an LSP server. The export contains a path
relative to the artifact and a source checksum; keep the source in place for
jumps, and regenerate the export after editing it.

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
The verification and replay harnesses are not implemented yet.

`nix develop -c scripts/check.sh` checks deterministic export, artifact
selection, and navigation using a clean, locally installed Neovim package.
Without Nix, run `scripts/check.sh` with Git, Python 3, Quint 0.33.1, and
Neovim 0.12+ on `PATH`.
