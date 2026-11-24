# nvim-quint-viewer

Read [Quint](https://quint.sh/) definitions as decision trees in Neovim.
From a `.qnt` file, open a read-only graph in the same window and follow
definitions in graph or source form with the Quint language server. The graph
shows the rules as written, not a simulation, proof, or map of reachable states.

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

Open `examples/approval.qnt` and run `:QuintView` from anywhere in the file.
It shows the file’s top-level operators and values in source order, grouped
by module. Imported definitions and nested bindings aren’t separate entries.
Destructuring is shown as source, without generated names.
Run `:QuintView` again to return to editable source at your previous
cursor position. Reopening the graph from source builds it from the saved file.

Put the graph cursor on `mayApprove` in the `allowed =` row and press `gd`
to open the focused graph of `mayApprove` at its heading. `Ctrl-O` returns to
the original graph position, and `Ctrl-I` goes forward again. `:QuintView` from
a focused `gd` graph shows its backing source at the declaration. For imports
and nested branches, try the [access review example](examples/access_review/).

- `gd` stays in graph mode for top-level operators and values, including
  imports. Each jump builds the destination graph on demand. Parameters and
  nested bindings have no standalone graph, so `gd` leaves you where you are.
- `gD` jumps to the definition in editable source, including for a parameter
  or nested binding such as `allowed` in `IF allowed`. The plugin does not
  change mappings in source buffers.
- `K` shows the language server's type and documentation in a preview without
  leaving the graph.
- `grr` opens a location list of source references, including the declaration.
  For imported symbols, Quint searches the source file and its imports, not the
  whole workspace. Other callers are not searched just because they're open.
  Press Enter on an entry to visit it, or use `:lclose` to close the list.

If the file you built the graph from changes, the old graph stays readable
but refuses new lookups. For imported symbols, the viewer also checks every
file Quint read through imports, including intermediate re-exports. An
edited, out-of-date, or unavailable import blocks imported lookups without
blocking local LSP requests. A local graph jump can still fail if Quint can't
build the destination graph, for example because an import is missing. The
viewer checks freshness again before acting on a reply. Save or reload the
affected files, then rebuild the graph with `:QuintView` from the caller’s source.
`gd` (and `gD` on imported symbols) only jumps if the server's destination
matches the declaration's mapped file, line, and byte column. For imported
symbols, a `grr` list must contain that same location, but this does not
guarantee every returned use is up to date. If
the server still returns outdated results, run `:lsp restart quint` from the
caller, wait for analysis, and try again. In particular, the viewer cannot
tell whether hover text came from the old import after a rebuild. It does not
refresh location lists already returned by the server. Quint language server 0.21.0 can report
incorrect columns after non-BMP characters (such as emoji) on the declaration
line; the viewer rejects `gd` jumps and imported `gD` jumps and reference lists
with mismatched columns.

Explicit `if`/`else` branches start expanded. On a `Yes` or `No` heading,
press `za` to toggle that branch, `zc` to close it, or `zo` to open it. A closed
branch keeps its heading visible. Independent folds are limited to 20 levels
by Neovim; deeper branches stay inside their ancestor’s fold. Native options
like `foldlevelstart` still apply on later buffer entry. Other expressions
are shown as source.

From source, pass names to show a subset in the requested order
(`:QuintView review mayApprove`).
Names are looked up in the module at the cursor. Outside a
module, the viewer uses the only module in the file, or the one named after
the file if there are several. If neither identifies a module, place the
cursor inside one. Modules don't have to match the filename.

Graph lookups work on indexed local and imported references when a single
LSP client attached to the backing source supports the requested operation.

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
