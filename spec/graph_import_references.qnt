// References to an aliased import and a same-spelled local definition.
module graph_import_references {
  type Request = { op: str, arg: str }
  type Notice = { level: str, reason: str }
  type Position = { file: str, line: int, column: int }
  type Lookup = { method: str, position: Position, includeDeclaration: bool }
  type View = {
    windows: int, focus: str, graphAtOrigin: bool, graphReadOnly: bool,
    loclistTitle: str, references: List[Position], lookups: List[Lookup], notices: List[Notice],
  }
  type Session = {
    request: Request, phase: str, selected: str, edit: str, otherCallerOpen: bool,
    graphUsesMovedPolicy: bool, serverUsesMovedPolicy: bool, view: View,
  }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val openOtherCallerRequest = { op: "openOtherCaller", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val selectImport = { op: "positionOnCall", arg: "remote::allowed" }
  pure val selectLocal = { op: "positionOnCall", arg: "allowed" }
  pure val editCallerRequest = { op: "editCaller", arg: "" }
  pure val editPolicyDiskRequest = { op: "editPolicyDisk", arg: "" }
  pure val editPolicyBufferRequest = { op: "editPolicyBuffer", arg: "" }
  pure val referencesRequest = { op: "references", arg: "" }
  pure val returnToCallerRequest = { op: "returnToCaller", arg: "" }
  pure val reanalyzeCallerRequest = { op: "reanalyzeCaller", arg: "" }
  pure val calls = Set(selectImport, selectLocal)
  pure val edits = Set(editCallerRequest, editPolicyDiskRequest, editPolicyBufferRequest)
  pure val requests = calls.union(edits).union(Set(openOtherCallerRequest, showRequest, referencesRequest,
    returnToCallerRequest, reanalyzeCallerRequest))

  pure val callerView: View = {
    windows: 1, focus: "caller.qnt", graphAtOrigin: false, graphReadOnly: false,
    loclistTitle: "", references: List(), lookups: List(), notices: List(),
  }
  pure def graphView(atOrigin: bool): View = {
    ...callerView, focus: "graph", graphAtOrigin: atOrigin, graphReadOnly: true,
  }
  pure val staleGraphWarning = { level: "warn", reason: "staleGraph" }
  pure val staleReferencesWarning = { level: "warn", reason: "staleReferences" }

  // Request positions are zero-based LSP coordinates at the caller occurrence.
  pure def requestAtCall(imported: bool): Lookup = {
    method: "references", position: { file: "caller.qnt", line: 4, column: if (imported) 8 else 29 },
    includeDeclaration: true,
  }
  // Location list positions use one-based rows and zero-based byte columns.
  // The fixture identities denote exact files, not just matching basenames.
  pure def policyDeclarationLine(moved: bool): int = if (moved) 3 else 2
  pure def scopedReferences(imported: bool, moved: bool): List[Position] = if (imported) List(
    { file: "caller.qnt", line: 5, column: 8 },
    { file: "caller.qnt", line: 6, column: 19 },
    { file: "policy.qnt", line: policyDeclarationLine(moved), column: 11 },
    { file: "policy.qnt", line: policyDeclarationLine(moved) + 1, column: 23 },
  ) else List(
    { file: "caller.qnt", line: 3, column: 11 },
    { file: "caller.qnt", line: 5, column: 29 },
  )
  // The old policy use is on the moved declaration's line, but at a
  // different column. Checking the file and line alone would accept it.
  pure def containsPolicyAnchor(references: List[Position], moved: bool): bool =
    references.foldl(false, (found, location) => found or
      location == { file: "policy.qnt", line: policyDeclarationLine(moved), column: 11 })
  pure def listTitle(imported: bool): str = if (imported) "Quint references (source + imports)" else "Quint references"
  pure def resultView(imported: bool, references: List[Position]): View = {
    ...graphView(true), windows: 2, focus: "locationList", loclistTitle: listTitle(imported),
    references: references, lookups: List(requestAtCall(imported)),
  }
  pure val staleGraphView: View = { ...graphView(true), notices: List(staleGraphWarning) }
  pure val staleReferencesView: View = {
    ...graphView(true), lookups: List(requestAtCall(true)), notices: List(staleReferencesWarning),
  }

  action init = session' = {
    request: initRequest, phase: "source", selected: "", edit: "none", otherCallerOpen: false,
    graphUsesMovedPolicy: false, serverUsesMovedPolicy: false, view: callerView,
  }
  action openOtherCaller = all {
    session.phase == "source",
    not(session.otherCallerOpen),
    session.edit == "none",
    session' = { ...session, request: openOtherCallerRequest, otherCallerOpen: true },
  }
  action showGraph = all {
    session.phase == "source",
    session' = { ...session, request: showRequest, phase: "graph", graphUsesMovedPolicy: session.edit == editPolicyDiskRequest.op,
      view: graphView(false) },
  }
  action positionOnCall(request: Request): bool = all {
    session.phase == "graph",
    calls.contains(request),
    session' = { ...session, request: request, phase: "call", selected: request.arg, view: graphView(true) },
  }
  action editSource(request: Request): bool = all {
    session.phase == "call",
    session.edit == "none",
    edits.contains(request),
    session' = { ...session, request: request, edit: request.op },
  }
  val importedCall = session.selected == selectImport.arg
  val staleGraph = session.edit == editCallerRequest.op or (importedCall and
    (session.edit == editPolicyBufferRequest.op or (session.edit == editPolicyDiskRequest.op and not(session.graphUsesMovedPolicy))))
  val references = scopedReferences(importedCall, session.serverUsesMovedPolicy)
  val serverAndGraphDisagree = importedCall and session.graphUsesMovedPolicy != session.serverUsesMovedPolicy
  action lookupReferences = all {
    session.phase == "call",
    session' = if (staleGraph) {
      ...session, request: referencesRequest, phase: "staleGraph", view: staleGraphView,
    } else if (importedCall and not(containsPolicyAnchor(references, session.graphUsesMovedPolicy))) {
      ...session, request: referencesRequest, phase: "staleReferences", view: staleReferencesView,
    } else {
      ...session, request: referencesRequest, phase: "result", view: resultView(importedCall, references),
    },
  }
  action returnToCaller = all {
    Set("staleGraph", "staleReferences").contains(session.phase),
    session.edit == editPolicyDiskRequest.op,
    session' = { ...session, request: returnToCallerRequest, phase: "source", view: callerView },
  }
  action reanalyzeCaller = all {
    session.phase == "source",
    session.edit == editPolicyDiskRequest.op,
    not(session.serverUsesMovedPolicy),
    session' = { ...session, request: reanalyzeCallerRequest, serverUsesMovedPolicy: true },
  }
  action perform(request: Request): bool = any {
    all { request == openOtherCallerRequest, openOtherCaller },
    all { request == showRequest, showGraph },
    all { calls.contains(request), positionOnCall(request) },
    all { edits.contains(request), editSource(request) },
    all { request == referencesRequest, lookupReferences },
    all { request == returnToCallerRequest, returnToCaller },
    all { request == reanalyzeCallerRequest, reanalyzeCaller },
  }
  action step = any {
    { nondet request = requests.oneOf(); perform(request) },
    all { Set("result", "staleGraph", "staleReferences").contains(session.phase), session' = session },
  }

  pure def positionSet(positions: List[Position]): Set[Position] =
    positions.foldl(Set(), (items, position) => items.union(Set(position)))
  // Presentation order is not a guarantee. Check the exact membership and
  // count, so duplicates or extra items cannot pass as the expected list.
  def observationMatches(observed: View): bool = all {
    session.view == { ...observed, references: session.view.references },
    session.view.references.length() == observed.references.length(),
    positionSet(session.view.references) == positionSet(observed.references),
  }
  val lookupKeepsReadOnlyGraphAtOrigin = (session.request == referencesRequest) implies
    (session.view.graphAtOrigin and session.view.graphReadOnly)
  val staleGraphWarnsWithoutRequest = (session.request == referencesRequest and staleGraph) implies
    session.view == staleGraphView
  val staleServerReplyDoesNotOpenList = (session.request == referencesRequest and not(staleGraph) and serverAndGraphDisagree) implies
    session.view == staleReferencesView
  val freshReferencesOpenScopedList = (session.request == referencesRequest and not(staleGraph) and not(serverAndGraphDisagree)) implies
    session.view == resultView(importedCall, scopedReferences(importedCall, session.graphUsesMovedPolicy))

  run freshImportedReferencesTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(referencesRequest)).expect(session.phase == "result" and freshReferencesOpenScopedList)
  run openOtherCallerDoesNotBroadenReferencesTest = init.then(perform(openOtherCallerRequest)).then(perform(showRequest))
    .then(perform(selectImport)).then(perform(referencesRequest))
    .expect(session.otherCallerOpen and session.phase == "result" and freshReferencesOpenScopedList)
  run freshLocalReferencesTest = init.then(perform(showRequest)).then(perform(selectLocal))
    .then(perform(referencesRequest)).expect(session.phase == "result" and freshReferencesOpenScopedList)
  run dirtyCallerRefusesImportedReferencesTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(editCallerRequest)).then(perform(referencesRequest))
    .expect(session.phase == "staleGraph" and staleGraphWarnsWithoutRequest)
  run dirtyPolicyRefusesImportedReferencesTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(editPolicyBufferRequest)).then(perform(referencesRequest))
    .expect(session.phase == "staleGraph" and staleGraphWarnsWithoutRequest)
  run movedPolicyRefusesImportedReferencesTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(editPolicyDiskRequest)).then(perform(referencesRequest))
    .expect(session.phase == "staleGraph" and staleGraphWarnsWithoutRequest)
  run movedPolicyDoesNotBlockLocalReferencesTest = init.then(perform(showRequest)).then(perform(selectLocal))
    .then(perform(editPolicyDiskRequest)).then(perform(referencesRequest))
    .expect(session.phase == "result" and freshReferencesOpenScopedList)
  run movedPolicyRefreshReferencesTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(editPolicyDiskRequest)).then(perform(referencesRequest))
    .expect(session.phase == "staleGraph" and staleGraphWarnsWithoutRequest)
    .then(perform(returnToCallerRequest)).then(perform(showRequest)).then(perform(selectImport))
    .then(perform(referencesRequest)).expect(session.phase == "staleReferences" and staleServerReplyDoesNotOpenList)
    .then(perform(returnToCallerRequest)).then(perform(reanalyzeCallerRequest)).then(perform(showRequest))
    .then(perform(selectImport)).then(perform(referencesRequest))
    .expect(session.phase == "result" and freshReferencesOpenScopedList)
}
