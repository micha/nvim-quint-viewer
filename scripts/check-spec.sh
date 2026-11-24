#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
export TMPDIR="$work"
if [ -n "${QMODEL_APALACHE_CACHE:-}" ]; then
  export QUINT_HOME="$QMODEL_APALACHE_CACHE"
fi

printf '%s\n' '{"workers":1,"maxHeap":"-Xmx256m","stackSize":"-Xss8m"}' > "$work/tlc.json"
verify() {
  spec=$1
  shift
  quint verify "$root/spec/$spec.qnt" --backend=tlc --tlc-config "$work/tlc.json" \
    --server-endpoint "${QMODEL_SPEC_ENDPOINT:-127.0.0.1:8822}" --invariants "$@"
}

histories() {
  spec=$1
  shift
  traces="$work/$spec"
  mkdir "$traces"
  quint test "$root/spec/$spec.qnt" --backend=typescript --seed=1 --out-itf="$traces/{test}_{seq}.itf.json"
  # A missing or renamed Quint test can otherwise be silently skipped.
  for test do
    set -- "$traces"/"${test}"_*.itf.json
    if [ "$#" -ne 1 ] || [ ! -s "$1" ]; then
      printf 'Expected one ITF trace for %s\n' "$test" >&2
      exit 1
    fi
  done
}

verify source_navigation sourceOnlyAfterFreshFollow noticeOnlyAfterChangedFollow \
  freshFollowOpensDefinition changedFollowKeepsViewer
histories source_navigation freshLocalDefinitionTest freshOperatorDefinitionTest changedAfterOpenTest

verify graph_navigation singleWindow graphIsReadOnly freshFollowReachesDefinition \
  staleFollowKeepsOrigin backRestoresOrigin closeYesBranchKeepsGraph
histories graph_navigation freshDefinitionAndBackTest dirtySourceRefusesDefinitionTest diskChangeAndRegenerateTest

verify branch_folding initiallyExpanded onlyVisibleBranchesFolded nativeFoldClosesOrOpens
histories branch_folding siblingFoldsTest nestedFoldsTest deepFoldContainsBodyTest

verify graph_lookups requestsUseSourceOccurrence freshHoverKeepsGraph freshReferencesOpenLocationList \
  staleLookupsWarnWithoutRequest unlinkedLookupsDoNothing
histories graph_lookups freshHoverTest freshReferencesTest dirtyHoverTest dirtyReferencesTest \
  changedDiskHoverTest changedDiskReferencesTest unlinkedHoverTest unlinkedReferencesTest

verify graph_import singleWindow graphIsReadOnly freshFollowResolvesScope \
  staleGraphWarnsWithoutRequest staleServerReplyDoesNotJump backRestoresOrigin
histories graph_import importedDefinitionAndBackTest localDefinitionAndBackTest dirtyCallerRefusesImportedDefinitionTest \
  movedPolicyRefusesImportedDefinitionTest dirtyPolicyRefusesImportedDefinitionTest \
  movedPolicyDoesNotBlockLocalDefinitionTest movedPolicyRefreshTest
