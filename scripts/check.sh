#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
mode= with_lsp=
for option do
  case "$option" in
    --worktree) mode=--worktree ;;
    --with-lsp) with_lsp=1 ;;
    *) printf 'Usage: %s [--worktree] [--with-lsp]\n' "$0" >&2; exit 2 ;;
  esac
done
if [ -n "$with_lsp" ] && ! command -v quint-language-server >/dev/null; then
  printf 'quint-language-server is required for --with-lsp; see spec/README.md\n' >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data"
export XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache"
export QMODEL_ROOT="$root" QMODEL_MODE="$mode"
mkdir -p "$work/source"
cp "$root/examples/approval.qnt" "$work/source/approval.qnt"

export_model() {
  python3 -B "$root/tools/export_model.py" "$work/source/approval.qnt" "$@"
}

export_model review -o "$work/approval.json"
export_model review -o "$work/duplicate.json"
cmp "$work/approval.json" "$work/duplicate.json"
if export_model missing -o "$work/missing.json" >"$work/errors" 2>&1; then
  printf 'Export of a nonexistent definition unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'no operator or value named' "$work/errors"
test ! -e "$work/missing.json"
python3 -B "$root/tests/export_source_review.py" "$work"

printf 'Deterministic graph export checks passed.\n'
# Pass either one --worktree option or no arguments to each replay.
set --
if [ -n "$mode" ]; then set -- "$mode"; fi
python3 -B "$root/tests/replay_graph_selection.py" "$@"
python3 -B "$root/tests/replay_branch_folding.py" "$@"
if [ -n "$with_lsp" ]; then
  python3 -B "$root/tests/replay_graph_navigation.py" "$@"
  python3 -B "$root/tests/replay_graph_lookups.py" "$@"
  python3 -B "$root/tests/replay_graph_import.py" "$@"
  python3 -B "$root/tests/replay_graph_import_hover.py" "$@"
  python3 -B "$root/tests/replay_graph_import_references.py" "$@"
fi
