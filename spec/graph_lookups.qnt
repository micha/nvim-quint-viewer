// Read-only LSP lookups on review in examples/approval.qnt.
module graph_lookups {
  type Request = { op: str, arg: str }
  type Notice = { level: str, reason: str }
  type Position = { file: str, line: int, column: int }
  type Lookup = { method: str, position: Position, includeDeclaration: bool }
  type View = {
    windows: int, focus: str, graphAtOrigin: bool, hover: str,
    references: List[Position], lookups: List[Lookup], notices: List[Notice]
  }
  type Session = { request: Request, phase: str, edit: str, view: View }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val selectRequest = { op: "positionOnCondition", arg: "allowed" }
  pure val unlinkedRequest = { op: "positionOnHeading", arg: "" }
  pure val bufferEditRequest = { op: "editSource", arg: "buffer" }
  pure val diskEditRequest = { op: "editSource", arg: "disk" }
  pure val hoverRequest = { op: "lookup", arg: "hover" }
  pure val referencesRequest = { op: "lookup", arg: "references" }
  pure val selections = Set(selectRequest, unlinkedRequest)
  pure val edits = Set(bufferEditRequest, diskEditRequest)
  pure val lookups = Set(hoverRequest, referencesRequest)
  pure val requests = selections.union(edits).union(lookups).union(Set(showRequest))

  pure val staleWarning = { level: "warn", reason: "staleGraph" }
  // LSP input rows and columns are zero-based. Location-list rows are
  // one-based; the observation normalizes its byte columns to zero-based.
  pure val guardPosition = { file: "approval.qnt", line: 9, column: 8 }
  pure val allowedReferences = List({ file: "approval.qnt", line: 9, column: 8 },
    { file: "approval.qnt", line: 10, column: 8 })
  pure val sourceView: View = {
    windows: 1, focus: "source", graphAtOrigin: false, hover: "", references: List(), lookups: List(), notices: List()
  }
  pure def graphView(atOrigin: bool): View = { ...sourceView, focus: "graph", graphAtOrigin: atOrigin }
  pure def freshLookup(method: str): View = {
    ...graphView(true), windows: 2,
    focus: if (method == "hover") "graph" else "locationList",
    hover: if (method == "hover") "val allowed: bool" else "",
    references: if (method == "references") allowedReferences else List(),
    lookups: List({ method: method, position: guardPosition, includeDeclaration: method == "references" }),
  }

  action init = session' = { request: initRequest, phase: "source", edit: "none", view: sourceView }

  action showGraph = all {
    session.phase == "source",
    session' = { ...session, request: showRequest, phase: "graph", view: graphView(false) },
  }

  action selectOccurrence(request: Request): bool = all {
    session.phase == "graph",
    selections.contains(request),
    session' = { ...session, request: request, phase: if (request == selectRequest) "linked" else "heading",
      view: graphView(true) },
  }

  action editSource(request: Request): bool = all {
    session.phase == "linked",
    session.edit == "none",
    edits.contains(request),
    session' = { ...session, request: request, edit: request.arg },
  }

  action lookup(request: Request): bool = all {
    Set("linked", "heading").contains(session.phase),
    lookups.contains(request),
    session' = if (session.phase == "heading") {
      ...session, request: request, phase: "unlinked", view: graphView(true)
    } else if (session.edit != "none") {
      ...session, request: request, phase: "stale", view: { ...graphView(true), notices: List(staleWarning) }
    } else {
      ...session, request: request, phase: "result", view: freshLookup(request.arg)
    },
  }

  action perform(request: Request): bool = any {
    all { request == showRequest, showGraph },
    all { selections.contains(request), selectOccurrence(request) },
    all { edits.contains(request), editSource(request) },
    all { lookups.contains(request), lookup(request) },
  }

  action step = any {
    {
      nondet request = requests.oneOf()
      perform(request)
    },
    all { Set("result", "stale", "unlinked").contains(session.phase), session' = session },
  }

  def observationMatches(observed: View): bool = session.view == observed

  val requestsUseSourceOccurrence = session.view.lookups.foldl(true, (ok, query) => ok and query.position == guardPosition)
  val freshHoverKeepsGraph = (session.phase == "result" and session.request == hoverRequest) implies
    session.view == freshLookup("hover")
  val freshReferencesOpenLocationList = (session.phase == "result" and session.request == referencesRequest) implies
    session.view == freshLookup("references")
  val staleLookupsWarnWithoutRequest = (session.phase == "stale") implies
    session.view == { ...graphView(true), notices: List(staleWarning) }
  val unlinkedLookupsDoNothing = (session.phase == "unlinked") implies session.view == graphView(true)

  run freshHoverTest = init.then(perform(showRequest)).then(perform(selectRequest))
    .then(perform(hoverRequest)).expect(session.phase == "result" and freshHoverKeepsGraph)
  run freshReferencesTest = init.then(perform(showRequest)).then(perform(selectRequest))
    .then(perform(referencesRequest)).expect(session.phase == "result" and freshReferencesOpenLocationList)
  run dirtyHoverTest = init.then(perform(showRequest)).then(perform(selectRequest)).then(perform(bufferEditRequest))
    .then(perform(hoverRequest)).expect(session.phase == "stale" and staleLookupsWarnWithoutRequest)
  run dirtyReferencesTest = init.then(perform(showRequest)).then(perform(selectRequest)).then(perform(bufferEditRequest))
    .then(perform(referencesRequest)).expect(session.phase == "stale" and staleLookupsWarnWithoutRequest)
  run changedDiskHoverTest = init.then(perform(showRequest)).then(perform(selectRequest)).then(perform(diskEditRequest))
    .then(perform(hoverRequest)).expect(session.phase == "stale" and staleLookupsWarnWithoutRequest)
  run changedDiskReferencesTest = init.then(perform(showRequest)).then(perform(selectRequest)).then(perform(diskEditRequest))
    .then(perform(referencesRequest)).expect(session.phase == "stale" and staleLookupsWarnWithoutRequest)
  run unlinkedHoverTest = init.then(perform(showRequest)).then(perform(unlinkedRequest))
    .then(perform(hoverRequest)).expect(session.phase == "unlinked" and unlinkedLookupsDoNothing)
  run unlinkedReferencesTest = init.then(perform(showRequest)).then(perform(unlinkedRequest))
    .then(perform(referencesRequest)).expect(session.phase == "unlinked" and unlinkedLookupsDoNothing)
}
