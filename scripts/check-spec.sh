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

verify graph_selection graphIsReadOnly cursorUsesEnclosingDefinition rejectionKeepsSource
histories graph_selection definitionNameTest sameLineAfterUnicodeTest nestedLocalUsesOuterTest \
  moduleHeaderIsNotDefinitionTest outsideDefinitionTest namedDefinitionsInOrderTest \
  namedDefinitionInSecondModuleTest ambiguousNamedModuleTest nameDoesNotCrossModulesTest \
  soleModuleFallbackTest variantIsNotADefinitionTest filenameFallbackTest cursorModuleBeatsFilenameTest \
  namedDefinitionInMacFileTest

verify graph_navigation singleWindow graphIsReadOnly freshFollowReachesDefinition \
  staleFollowKeepsOrigin backRestoresOrigin closeYesBranchKeepsGraph
histories graph_navigation freshDefinitionAndBackTest dirtySourceRefusesDefinitionTest diskChangeAndRegenerateTest

verify graph_definition_mode singleWindow onlySourceEditable followWaitsAtOrigin staleDefinitionKeepsOrigin \
  unrenderableOffersRaw wrongScopeKeepsOrigin freshReplyPreservesMode exactNativeHistory rawGdRemainsInSource
histories graph_definition_mode localGraphAndHistoryTest importedGraphAndHistoryTest importedGraphSupportsSecondHopTest \
  parameterAdvisesRawAndJumpsTest bindingAdvisesRawAndJumpsTest rawSourceMapStillWorksTest importedRawDefinitionTest staleGraphBeforeRequestTest \
  staleCallerBeforeReplyTest stalePolicyBeforeReplyTest stalePolicyBeforeRawReplyTest \
  stalePolicyDoesNotAffectLocalGraphTest wrongScopeReplyTest

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
  movedPolicyDoesNotBlockLocalDefinitionTest movedPolicyRefreshTest shiftedPolicyRefreshTest

verify graph_import_hover lookupsKeepReadOnlyGraphAtOrigin freshHoverUsesCallerOccurrenceAndScopedDocs \
  staleHoverWarnsWithoutRequest
histories graph_import_hover freshImportedHoverTest freshLocalHoverTest dirtyCallerRefusesImportedHoverTest \
  movedPolicyRefusesImportedHoverTest dirtyPolicyRefusesImportedHoverTest movedPolicyDoesNotBlockLocalHoverTest

verify graph_import_references lookupKeepsReadOnlyGraphAtOrigin freshReferencesOpenScopedList \
  staleGraphWarnsWithoutRequest staleServerReplyDoesNotOpenList
histories graph_import_references freshImportedReferencesTest openOtherCallerDoesNotBroadenReferencesTest \
  freshLocalReferencesTest dirtyCallerRefusesImportedReferencesTest dirtyPolicyRefusesImportedReferencesTest \
  movedPolicyRefusesImportedReferencesTest movedPolicyDoesNotBlockLocalReferencesTest movedPolicyRefreshReferencesTest

verify graph_import_chain changedWrapperBlocksImport freshLookupUsesCurrentScope backRestoresGraph \
  waitingKeepsGraph staleReplyKeepsGraph freshReplyUsesCurrentScope
histories graph_import_chain freshImportedDefinitionTest freshImportedHoverTest freshImportedReferencesTest \
  diskWrapperDefinitionRecoveryTest diskWrapperHoverRecoveryTest diskWrapperReferencesRecoveryTest \
  dirtyWrapperRefusesDefinitionTest dirtyWrapperRefusesHoverTest dirtyWrapperRefusesReferencesTest \
  changedWrapperAllowsLocalDefinitionTest changedWrapperAllowsLocalHoverTest changedWrapperAllowsLocalReferencesTest \
  delayedFreshDefinitionTest delayedFreshHoverTest delayedFreshReferencesTest \
  delayedDirtyCallerDefinitionTest delayedDirtyCallerHoverTest delayedDirtyCallerReferencesTest \
  delayedDiskWrapperDefinitionTest delayedDiskWrapperHoverTest delayedDiskWrapperReferencesTest \
  delayedDirtyWrapperDefinitionTest delayedDirtyWrapperHoverTest delayedDirtyWrapperReferencesTest \
  delayedLocalDefinitionTest delayedLocalHoverTest delayedLocalReferencesTest
