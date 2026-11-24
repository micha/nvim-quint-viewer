#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-}
if [ "$#" -gt 1 ] || { [ -n "$mode" ] && [ "$mode" != --worktree ]; }; then
  printf 'Usage: %s [--worktree]\n' "$0" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data"
export XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache"
export QMODEL_ROOT="$root" QMODEL_MODE="$mode"
mkdir -p "$work/config/nvim" "$work/source"
cp "$root/examples/approval.qnt" "$work/source/approval.qnt"

export_model() {
  python3 -B "$root/tools/export_model.py" "$work/source/approval.qnt" "$@"
}

export_model review -o "$work/approval.qmodel.json"
export_model review -o "$work/duplicate.qmodel.json"
cmp "$work/approval.qmodel.json" "$work/duplicate.qmodel.json"
if export_model missing -o "$work/missing.qmodel.json" >"$work/errors" 2>&1; then
  printf 'Export of a nonexistent definition unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'no operator or value named' "$work/errors"
test ! -e "$work/missing.qmodel.json"

cp "$root/tests/init.lua" "$work/config/nvim/init.lua"
run_viewer() {
  nvim --headless --cmd 'set columns=150' "$1" "+luafile $root/tests/viewer.lua"
}
run_viewer "$work/approval.qmodel.json"
printf '{}\n' >"$work/ordinary.json"
QMODEL_CASE=ordinary run_viewer "$work/ordinary.json"
printf '{}\n' >"$work/invalid.qmodel.json"
QMODEL_CASE=invalid run_viewer "$work/invalid.qmodel.json"
printf '\n// Edit after export.\n' >>"$work/source/approval.qnt"
QMODEL_CASE=stale run_viewer "$work/approval.qmodel.json"
printf 'Deterministic export and Neovim viewer checks passed.\n'
