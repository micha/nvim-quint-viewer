# Agent guide

Read [README.md](README.md) for installation and supported workflows. This
repository is a standalone Neovim plugin; DML is not a build or test dependency.

## Boundaries

- `plugin/quint_viewer.lua` registers the `*.qmodel.json` entry point.
- `lua/quint_viewer/` renders an export and handles navigation. Opening an
  artifact must not run external commands or require a language server. Validate
  the format before rendering and check the source fingerprint before jumping.
- `tools/export_model.py` and `tools/symbol_index.py` build the decision tree and
  symbol index using Quint’s parsed and typechecked output. Keep definition
  identities scoped; do not resolve a reference by spelling alone. Keep the DML
  presentation rules opt-in.
- The exporter and viewer share the versioned `quint-decision-model` JSON
  contract. Change both sides and the tests together if it changes. Output must
  be deterministic and must not contain absolute source paths or timestamps.
- Keep generated exports and temporary check results untracked.

## Validation

Run `nix develop -c scripts/check.sh` (or run the script with the tools on
`PATH`). The installation check clones the committed local `HEAD` using
`vim.pack.add()`. For uncommitted edits, pass `--worktree` to `scripts/check.sh`
to load the runtime directly, then rerun the default check after committing.

Add focused tests for changes to the artifact or viewer. Test navigation in
headless Neovim, and do not report unrun or unavailable checks as passing.
