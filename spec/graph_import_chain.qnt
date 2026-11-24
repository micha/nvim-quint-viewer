// The caller imports a wrapper which re-exports an unchanged policy file.
// A wrapper-only edit can redirect the same occurrence to another declaration.
module graph_import_chain {
  type Request = { op: str, arg: str }
  type Position = { file: str, line: int, column: int }
  type Notice = { level: str, reason: str }
  type Lookup = { method: str, position: Position, includeDeclaration: bool }
  type View = {
    windows: int, focus: str, graphAtOrigin: bool, graphReadOnly: bool,
    position: Position, hover: str, loclistTitle: str, references: List[Position],
    lookups: List[Lookup], notices: List[Notice], heldReply: bool,
  }
  type Session = {
    request: Request, phase: str, selected: str, edit: str, refreshed: bool, heldMethod: str, view: View,
  }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val selectImport = { op: "positionOnCall", arg: "remote::allowed" }
  pure val selectLocal = { op: "positionOnCall", arg: "allowed" }
  pure val editDisk = { op: "editWrapperDisk", arg: "" }
  pure val editBuffer = { op: "editWrapperBuffer", arg: "" }
  pure val definition = { op: "definition", arg: "" }
  pure val hoverRequest = { op: "hover", arg: "" }
  pure val refs = { op: "references", arg: "" }
  pure val returnRequest = { op: "returnToCaller", arg: "" }
  pure val reanalyze = { op: "reanalyzeCaller", arg: "" }
  pure val back = { op: "back", arg: "" }
  pure val calls = Set(selectImport, selectLocal)
  pure val edits = Set(editDisk, editBuffer)
  pure val lookupRequests = Set(definition, hoverRequest, refs)
  pure def hold(method: Request): Request = { op: "holdLookup", arg: method.op }
  pure val heldLookups = lookupRequests.map(hold)
  pure val editCaller = { op: "editCallerBuffer", arg: "" }
  pure val deliver = { op: "deliverReply", arg: "" }
  pure val pendingEdits = edits.union(Set(editCaller))
  pure val requests = calls.union(pendingEdits).union(lookupRequests).union(heldLookups)
    .union(Set(showRequest, returnRequest, reanalyze, back, deliver))

  pure val callerView: View = {
    windows: 1, focus: "caller.qnt", graphAtOrigin: false, graphReadOnly: false,
    position: { file: "", line: 0, column: 0 }, hover: "", loclistTitle: "", references: List(),
    lookups: List(), notices: List(), heldReply: false,
  }
  pure def graphView(atOrigin: bool): View = {
    ...callerView, focus: "graph", graphAtOrigin: atOrigin, graphReadOnly: true,
  }
  pure val staleView: View = {
    ...graphView(true), notices: List({ level: "warn", reason: "staleGraph" }),
  }
  pure def requestAtCall(method: str, imported: bool): Lookup = {
    method: method,
    position: { file: "caller.qnt", line: 5, column: if (imported) 8 else 29 },
    includeDeclaration: method == "references",
  }
  pure def declaration(imported: bool, refreshed: bool): Position = if (imported) {
    file: "policy.qnt", line: if (refreshed) 9 else 3, column: 11,
  } else { file: "caller.qnt", line: 4, column: 11 }
  pure def hoverText(imported: bool, refreshed: bool): str = if (imported) {
    if (refreshed) "pure def allowed: (bool) => bool | Alternate transitive policy."
    else "pure def allowed: (bool) => bool | Original transitive policy."
  } else "pure def allowed: (bool) => bool | Local policy."
  pure def referenceList(imported: bool, refreshed: bool): List[Position] = if (imported) List(
    declaration(true, refreshed),
    { file: "policy.qnt", line: declaration(true, refreshed).line + 1, column: if (refreshed) 26 else 23 },
    { file: "caller.qnt", line: 6, column: 8 },
    { file: "caller.qnt", line: 7, column: 19 },
  ) else List(declaration(false, false), { file: "caller.qnt", line: 6, column: 29 })
  pure def result(method: str, imported: bool, refreshed: bool): View = {
    val requested = { ...graphView(true), lookups: List(requestAtCall(method, imported)) }
    if (method == "definition") {
      val target = declaration(imported, refreshed)
      { ...requested, focus: target.file, position: target, graphAtOrigin: false }
    } else if (method == "hover") {
      { ...requested, windows: 2, hover: hoverText(imported, refreshed) }
    } else {
      { ...requested, windows: 2, focus: "locationList", references: referenceList(imported, refreshed),
        loclistTitle: if (imported) "Quint references (source + imports)" else "Quint references" }
    }
  }

  pure def awaitingReply(lookups: List[Lookup]): View = {
    ...graphView(true), lookups: lookups, heldReply: true,
  }
  pure def replyResult(method: str, imported: bool): View = {
    ...result(method, imported, false), lookups: List(),
  }

  action init = session' = {
    request: initRequest, phase: "source", selected: "", edit: "none", refreshed: false,
    heldMethod: "", view: callerView,
  }
  val imported = session.selected == selectImport.arg
  val stale = (session.edit == editCaller.op or (imported and session.edit != "none")) and not(session.refreshed)
  action perform(request: Request): bool = any {
    all {
      request == showRequest, session.phase == "source", session.edit == "none" or session.refreshed,
      session' = { ...session, request: request, phase: "graph", view: graphView(false) },
    },
    all {
      calls.contains(request), session.phase == "graph",
      session' = { ...session, request: request, phase: "call", selected: request.arg, view: graphView(true) },
    },
    all {
      edits.contains(request), session.phase == "call", session.edit == "none",
      session' = { ...session, request: request, edit: request.op },
    },
    all {
      lookupRequests.contains(request), session.phase == "call",
      session' = if (stale) { ...session, request: request, phase: "blocked", view: staleView }
        else { ...session, request: request, phase: "result", view: result(request.op, imported, session.refreshed) },
    },
    // A real reply arrives at the transport but has not reached the viewer yet.
    all {
      heldLookups.contains(request), session.phase == "call", session.edit == "none",
      session' = { ...session, request: request, phase: "held", heldMethod: request.arg,
        view: awaitingReply(List(requestAtCall(request.arg, imported))) },
    },
    all {
      pendingEdits.contains(request), session.phase == "held", session.edit == "none",
      session' = { ...session, request: request, edit: request.op, view: awaitingReply(List()) },
    },
    all {
      request == deliver, session.phase == "held",
      session' = { ...session, request: request, phase: "completed",
        view: if (stale) staleView else replyResult(session.heldMethod, imported) },
    },
    all {
      request == returnRequest, session.phase == "blocked", session.edit == editDisk.op,
      session' = { ...session, request: request, phase: "source", selected: "", view: callerView },
    },
    all {
      request == reanalyze, session.phase == "source", session.edit == editDisk.op, not(session.refreshed),
      session' = { ...session, request: request, refreshed: true },
    },
    all {
      request == back,
      (session.phase == "result" and session.request == definition) or
        (session.phase == "completed" and session.heldMethod == definition.op and not(stale)),
      session' = { ...session, request: request, phase: "back", view: graphView(true) },
    },
  }
  action step = any {
    { nondet request = requests.oneOf(); perform(request) },
    all { Set("blocked", "result", "completed", "back").contains(session.phase), session' = session },
  }

  pure def positionSet(positions: List[Position]): Set[Position] =
    positions.foldl(Set(), (items, position) => items.union(Set(position)))
  def observationMatches(observed: View): bool = all {
    session.view == { ...observed, references: session.view.references },
    session.view.references.length() == observed.references.length(),
    positionSet(session.view.references) == positionSet(observed.references),
  }
  val changedWrapperBlocksImport = (lookupRequests.contains(session.request) and stale) implies session.view == staleView
  val freshLookupUsesCurrentScope = (lookupRequests.contains(session.request) and not(stale)) implies
    session.view == result(session.request.op, imported, session.refreshed)
  val backRestoresGraph = (session.request == back) implies session.view == graphView(true)
  val waitingKeepsGraph = (session.phase == "held") implies session.view == awaitingReply(
    if (heldLookups.contains(session.request)) List(requestAtCall(session.heldMethod, imported)) else List())
  val staleReplyKeepsGraph = (session.request == deliver and stale) implies session.view == staleView
  val freshReplyUsesCurrentScope = (session.request == deliver and not(stale)) implies
    session.view == replyResult(session.heldMethod, imported)

  action openAtCall(call: Request): bool = perform(showRequest).then(perform(call))
  action freshImport(method: Request): bool = openAtCall(selectImport).then(perform(method))
  action blockedImport(edit: Request, method: Request): bool = openAtCall(selectImport).then(perform(edit)).then(perform(method))
  action recoveredImport(method: Request): bool = blockedImport(editDisk, method).then(perform(returnRequest))
    .then(perform(reanalyze)).then(freshImport(method))
  action unaffectedLocal(method: Request): bool = openAtCall(selectLocal).then(perform(editDisk)).then(perform(method))

  val resultMatches = session.phase == "result" and freshLookupUsesCurrentScope
  val blockedAsStale = session.phase == "blocked" and changedWrapperBlocksImport
  run freshImportedDefinitionTest = init.then(freshImport(definition)).expect(resultMatches)
    .then(perform(back)).expect(backRestoresGraph)
  run freshImportedHoverTest = init.then(freshImport(hoverRequest)).expect(resultMatches)
  run freshImportedReferencesTest = init.then(freshImport(refs)).expect(resultMatches)
  run diskWrapperDefinitionRecoveryTest = init.then(recoveredImport(definition)).expect(session.refreshed and resultMatches)
    .then(perform(back)).expect(backRestoresGraph)
  run diskWrapperHoverRecoveryTest = init.then(recoveredImport(hoverRequest)).expect(session.refreshed and resultMatches)
  run diskWrapperReferencesRecoveryTest = init.then(recoveredImport(refs)).expect(session.refreshed and resultMatches)
  run dirtyWrapperRefusesDefinitionTest = init.then(blockedImport(editBuffer, definition)).expect(blockedAsStale)
  run dirtyWrapperRefusesHoverTest = init.then(blockedImport(editBuffer, hoverRequest)).expect(blockedAsStale)
  run dirtyWrapperRefusesReferencesTest = init.then(blockedImport(editBuffer, refs)).expect(blockedAsStale)
  run changedWrapperAllowsLocalDefinitionTest = init.then(unaffectedLocal(definition)).expect(resultMatches)
    .then(perform(back)).expect(backRestoresGraph)
  run changedWrapperAllowsLocalHoverTest = init.then(unaffectedLocal(hoverRequest)).expect(resultMatches)
  run changedWrapperAllowsLocalReferencesTest = init.then(unaffectedLocal(refs)).expect(resultMatches)

  action waitAtCall(call: Request, method: Request): bool = openAtCall(call).then(perform(hold(method)))
  action freshDelay(method: Request): bool = waitAtCall(selectImport, method).then(perform(deliver))
  action staleDelay(edit: Request, method: Request): bool = waitAtCall(selectImport, method)
    .then(perform(edit)).then(perform(deliver))
  action localDelay(method: Request): bool = waitAtCall(selectLocal, method)
    .then(perform(editDisk)).then(perform(deliver))
  val replyAccepted = session.phase == "completed" and not(stale) and freshReplyUsesCurrentScope
  val replyDiscarded = session.phase == "completed" and stale and staleReplyKeepsGraph

  run delayedFreshDefinitionTest = init.then(freshDelay(definition)).expect(replyAccepted)
    .then(perform(back)).expect(backRestoresGraph)
  run delayedFreshHoverTest = init.then(freshDelay(hoverRequest)).expect(replyAccepted)
  run delayedFreshReferencesTest = init.then(freshDelay(refs)).expect(replyAccepted)
  run delayedDirtyCallerDefinitionTest = init.then(staleDelay(editCaller, definition)).expect(replyDiscarded)
  run delayedDirtyCallerHoverTest = init.then(staleDelay(editCaller, hoverRequest)).expect(replyDiscarded)
  run delayedDirtyCallerReferencesTest = init.then(staleDelay(editCaller, refs)).expect(replyDiscarded)
  run delayedDiskWrapperDefinitionTest = init.then(staleDelay(editDisk, definition)).expect(replyDiscarded)
  run delayedDiskWrapperHoverTest = init.then(staleDelay(editDisk, hoverRequest)).expect(replyDiscarded)
  run delayedDiskWrapperReferencesTest = init.then(staleDelay(editDisk, refs)).expect(replyDiscarded)
  run delayedDirtyWrapperDefinitionTest = init.then(staleDelay(editBuffer, definition)).expect(replyDiscarded)
  run delayedDirtyWrapperHoverTest = init.then(staleDelay(editBuffer, hoverRequest)).expect(replyDiscarded)
  run delayedDirtyWrapperReferencesTest = init.then(staleDelay(editBuffer, refs)).expect(replyDiscarded)
  run delayedLocalDefinitionTest = init.then(localDelay(definition)).expect(replyAccepted)
    .then(perform(back)).expect(backRestoresGraph)
  run delayedLocalHoverTest = init.then(localDelay(hoverRequest)).expect(replyAccepted)
  run delayedLocalReferencesTest = init.then(localDelay(refs)).expect(replyAccepted)
}
