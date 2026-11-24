// Hover over same-spelled definitions in the caller and its imported module.
module graph_import_hover {
  type Request = { op: str, arg: str }
  type Notice = { level: str, reason: str }
  type Position = { file: str, line: int, column: int }
  type Lookup = { method: str, position: Position }
  type View = {
    windows: int, focus: str, atOrigin: bool, modifiable: bool,
    hover: List[str], lookups: List[Lookup], notices: List[Notice],
  }
  type Session = { request: Request, phase: str, selected: str, edit: str, view: View }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val selectImport = { op: "positionOnCall", arg: "remote::allowed" }
  pure val selectLocal = { op: "positionOnCall", arg: "allowed" }
  pure val editCallerRequest = { op: "editCaller", arg: "" }
  pure val editPolicyDiskRequest = { op: "editPolicyDisk", arg: "" }
  pure val editPolicyBufferRequest = { op: "editPolicyBuffer", arg: "" }
  pure val hoverRequest = { op: "hover", arg: "" }
  pure val referencesRequest = { op: "references", arg: "" }
  pure val calls = Set(selectImport, selectLocal)
  pure val edits = Set(editCallerRequest, editPolicyDiskRequest, editPolicyBufferRequest)
  pure val requests = calls.union(edits).union(Set(showRequest, hoverRequest, referencesRequest))

  pure val sourceView: View = {
    windows: 1, focus: "caller.qnt", atOrigin: false, modifiable: true,
    hover: List(), lookups: List(), notices: List(),
  }
  pure def graphView(atOrigin: bool): View = { ...sourceView, focus: "graph", atOrigin: atOrigin, modifiable: false }
  pure val staleWarning = { level: "warn", reason: "staleGraph" }
  pure val rejectedView: View = { ...graphView(true), notices: List(staleWarning) }
  // Both hover requests use the caller's exact fixture URI and zero-based LSP
  // position. The import is a freshness dependency, not the request destination.
  pure def callPosition(imported: bool): Position = { file: "caller.qnt", line: 6, column: if (imported) 8 else 29 }
  pure def hoverText(imported: bool): List[str] = List("pure def allowed: (bool) => bool",
    if (imported) "Imported policy check." else "Local check.")
  pure def preview(imported: bool): View = {
    ...graphView(true), windows: 2, hover: hoverText(imported),
    lookups: List({ method: "hover", position: callPosition(imported) }),
  }

  action init = session' = { request: initRequest, phase: "source", selected: "", edit: "none", view: sourceView }
  action showGraph = all {
    session.phase == "source",
    session' = { ...session, request: showRequest, phase: "graph", view: graphView(false) },
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
  val staleGraph = session.edit == editCallerRequest.op or
    (importedCall and Set(editPolicyDiskRequest.op, editPolicyBufferRequest.op).contains(session.edit))
  action lookupHover = all {
    session.phase == "call",
    session' = if (staleGraph) {
      ...session, request: hoverRequest, phase: "rejected", view: rejectedView,
    } else {
      ...session, request: hoverRequest, phase: "preview", view: preview(importedCall),
    },
  }
  action importedReferences = all {
    session.phase == "call",
    importedCall,
    session' = { ...session, request: referencesRequest, phase: "unsupported", view: graphView(true) },
  }
  action perform(request: Request): bool = any {
    all { request == showRequest, showGraph },
    all { calls.contains(request), positionOnCall(request) },
    all { edits.contains(request), editSource(request) },
    all { request == hoverRequest, lookupHover },
    all { request == referencesRequest, importedReferences },
  }
  action step = any {
    { nondet request = requests.oneOf(); perform(request) },
    all { Set("rejected", "preview", "unsupported").contains(session.phase), session' = session },
  }

  def observationMatches(observed: View): bool = session.view == observed

  val lookupsKeepReadOnlyGraphAtOrigin = Set(hoverRequest, referencesRequest).contains(session.request) implies all {
    session.view.focus == "graph", session.view.atOrigin, not(session.view.modifiable),
  }
  val freshHoverUsesCallerOccurrenceAndScopedDocs = (session.request == hoverRequest and not(staleGraph)) implies all {
    session.view.windows == 2,
    session.view.hover == hoverText(importedCall),
    session.view.lookups == List({ method: "hover", position: callPosition(importedCall) }),
    session.view.notices == List(),
  }
  val staleHoverWarnsWithoutRequest = (session.request == hoverRequest and staleGraph) implies
    session.view == rejectedView
  val importedReferencesDoNothing = (session.request == referencesRequest) implies
    (importedCall and session.view == graphView(true))

  run freshImportedHoverTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(hoverRequest)).expect(session.phase == "preview" and freshHoverUsesCallerOccurrenceAndScopedDocs)
  run freshLocalHoverTest = init.then(perform(showRequest)).then(perform(selectLocal))
    .then(perform(hoverRequest)).expect(session.phase == "preview" and freshHoverUsesCallerOccurrenceAndScopedDocs)
  run dirtyCallerRefusesImportedHoverTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(editCallerRequest)).then(perform(hoverRequest))
    .expect(session.phase == "rejected" and staleHoverWarnsWithoutRequest)
  run movedPolicyRefusesImportedHoverTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(editPolicyDiskRequest)).then(perform(hoverRequest))
    .expect(session.phase == "rejected" and staleHoverWarnsWithoutRequest)
  run dirtyPolicyRefusesImportedHoverTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(editPolicyBufferRequest)).then(perform(hoverRequest))
    .expect(session.phase == "rejected" and staleHoverWarnsWithoutRequest)
  run movedPolicyDoesNotBlockLocalHoverTest = init.then(perform(showRequest)).then(perform(selectLocal))
    .then(perform(editPolicyDiskRequest)).then(perform(hoverRequest))
    .expect(session.phase == "preview" and freshHoverUsesCallerOccurrenceAndScopedDocs)
  run importedReferencesDoNothingTest = init.then(perform(showRequest)).then(perform(selectImport))
    .then(perform(referencesRequest)).expect(session.phase == "unsupported" and importedReferencesDoNothing)
}
