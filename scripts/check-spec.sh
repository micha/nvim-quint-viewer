#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
spec="$root/spec/source_navigation.qnt"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
export TMPDIR="$work"
if [ -n "${QMODEL_APALACHE_CACHE:-}" ]; then
  export QUINT_HOME="$QMODEL_APALACHE_CACHE"
fi

printf '%s\n' '{"workers":1,"maxHeap":"-Xmx256m","stackSize":"-Xss8m"}' > "$work/tlc.json"
quint verify "$spec" --backend=tlc --tlc-config "$work/tlc.json" \
  --server-endpoint "${QMODEL_SPEC_ENDPOINT:-127.0.0.1:8822}" \
  --invariants sourceOnlyAfterFreshFollow noticeOnlyAfterChangedFollow \
  freshFollowOpensDefinition changedFollowKeepsViewer

quint test "$spec" --backend=typescript --seed=1 --out-itf="$work/{test}_{seq}.itf.json"
# A missing or renamed Quint test can otherwise be silently skipped.
for test in freshLocalDefinitionTest freshOperatorDefinitionTest changedAfterOpenTest; do
  set -- "$work"/"${test}"_*.itf.json
  if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
    printf 'Expected one ITF trace for %s\n' "$test" >&2
    exit 1
  fi
done
