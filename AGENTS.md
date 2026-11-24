# Agent guide

Read [README.md](README.md) for installation and supported workflows. This
repository is a standalone Neovim plugin; DML is not a build or test dependency.

## Boundaries

- `plugin/quint_viewer.lua` registers `:QuintView`. Only an explicit source view
  can invoke the exporter or use a language server. Validate the export format
  before rendering and check source fingerprints before using mapped locations.
- The source graph is a separate read-only buffer. Visualize explicit Quint
  structure, show other expressions as source, and leave editing and navigation
  history to Neovim. Use the attached Quint LSP for definitions, hover, and
  references.
- `tools/export_model.py` and `tools/symbol_index.py` build the decision tree and
  source mappings using Quint’s parsed and typechecked output. Keep definition
  identities scoped; do not resolve a reference by spelling alone. Do not add
  DML-specific semantics or presentation to the viewer.
- The exporter and viewer share the versioned `quint-decision-model` JSON
  contract. Change both sides and the tests together if it changes. Output must
  be deterministic and must not contain absolute source paths or timestamps.
- Keep generated exports and temporary check results untracked.

## Quint-first development

Use this workflow for new features and changes to observable behavior, not for
behavior-preserving refactors or cosmetic edits.

1. **Model and verify the design before implementing it.** Specify the public
   actions, state transitions, and observable guarantees in Quint. Run
   `quint verify` and record what was checked, including any bounds. Include
   representative success and rejection histories so a design that disables
   the action cannot pass on safety alone.
2. **Implement and replay.** Use a thin trace interpreter to replay the Quint
   histories through the real plugin entry points and keymaps in clean,
   headless Neovim. The interpreter records observable results (such as the
   focused buffer, cursor, panes, and notifications); Quint judges them using
   the verified transition rules. Include a negative control to show that the
   verdict rejects incorrect observations.

Verification checks the design; replay checks the implementation on the
histories exercised. Keep them separate, and keep the existing exporter and
installation checks. Verification and replay tooling are development-only and
must not depend on a DML checkout. See the [specification roadmap](spec/README.md)
for the separate model verification and plugin replay commands.

## Validation

Run `nix develop -c scripts/check.sh` (or run the script with the tools on
`PATH`). The installation check clones the committed local `HEAD` using
`vim.pack.add()`. For uncommitted edits, pass `--worktree` to `scripts/check.sh`
to load the runtime directly, then rerun the default check after committing.

Add focused tests for changes to graph generation or the viewer. For source-graph
changes, also pass `--with-lsp` with the upstream server on `PATH`; see
[replay setup](spec/README.md#replay-the-source-graph). Test navigation in
headless Neovim, and do not report unrun or unavailable checks as passing.
