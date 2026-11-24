# nvim-quint-viewer

Read a [Quint](https://quint.sh/) definition as a decision tree in Neovim.
From a `.qnt` file, open a read-only graph in the same window and navigate
back to ordinary source with the Quint language server. The graph shows the
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

Choose one source. `vim.pack` clones the checkout; use
`:lua vim.pack.update({ 'nvim-quint-viewer' })` to update a managed install.
For live plugin development instead, prepend the checkout to `runtimepath`.

## View a saved Quint file

Put Python 3.10+ and `quint` on `PATH` to render a graph. For navigation and
lookups, install the
[Quint language server](https://www.npmjs.com/package/@informalsystems/quint-language-server)
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

Open `examples/approval.qnt`, place the cursor on the `review` definition
name, and run `:QuintView`. Put the cursor on `allowed` in `IF allowed` and
press `gd` to jump to its definition. `Ctrl-O` returns to the graph at the
original cursor position. The graph is read-only;
the real `.qnt` buffer is unchanged and still editable. For imports and
nested branches, try the [access review example](examples/access_review/).

- `K` shows the language server's type and documentation in a preview without
  leaving the graph.
- `grr` opens a location list of source references, including the declaration.
  For imported symbols, Quint searches the source file and its imports, not the
  whole workspace. Other callers are not searched just because they're open.
  Press Enter on an entry to visit it, or use `:lclose` to close the list.

If the file you built the graph from changes, the old graph stays readable
but refuses new lookups. For an imported symbol, the viewer also checks the
file that defines it. An edited or unavailable file blocks lookups on that
symbol without blocking local lookups. Save or reload any affected files, then
rebuild the graph with `:QuintView review` from the caller. An imported reference
list must include the declaration at its mapped line and column. This check
can catch a moved declaration but does not guarantee every returned use is up
to date. If the server still returns outdated results, run `:lsp restart quint`
from the caller, wait for analysis, and try again. The viewer does not refresh
location lists already returned by the server. Quint language server 0.21.0
can report incorrect columns after non-BMP characters (such as emoji) on the
declaration line; the viewer rejects imported lists with mismatched columns.

Explicit `if`/`else` branches start expanded. On a `Yes` or `No` heading,
press `za` to toggle that branch, `zc` to close it, or `zo` to open it. A closed
branch keeps its heading visible. Independent folds are limited to 20 levels
by Neovim; deeper branches stay inside their ancestor’s fold. Native options
like `foldlevelstart` still apply on later buffer entry. Other expressions
are shown as source.

With no arguments, `:QuintView` selects the top-level operator or value at
its definition name or inside its body. A local binding selects the
surrounding top-level definition. Qualifiers such as `pure` and outer
grouping punctuation may fall outside the mapped range.

Pass names to show definitions in order (`:QuintView review mayApprove`).
Names are looked up in the module at the cursor. Outside a
module, the viewer uses the only module in the file, or the one named after
the file if there are several. If neither identifies a module, place the
cursor inside one. Modules don't have to match the filename.

`gd`, `K`, and `grr` work on indexed local and imported references when a
single attached LSP client supports the requested operation.

## Develop

New features and observable behavior changes follow the
[Quint-first workflow](AGENTS.md#quint-first-development): verify the design
before implementing it, then replay Quint histories against headless Neovim.
See the [specification roadmap](spec/README.md) for the selection, navigation,
folding, and LSP lookup models. Run `nix develop .#spec -c scripts/check-spec.sh` to
verify them independently of the plugin.

`nix develop -c scripts/check.sh` checks deterministic graph generation and
replays graph selection and native folds against a clean plugin installation
from the committed `HEAD`. Pass `--worktree` to test uncommitted changes. To
also replay navigation and lookups with the real server, add `--with-lsp`
with a compatible Quint CLI and server on `PATH`; see the
[replay instructions](spec/README.md#replay-the-source-graph).
