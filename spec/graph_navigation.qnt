// The read-only source projection of review in examples/approval.qnt.
module graph_navigation {
  type Request = { op: str, arg: str }
  type Notice = { level: str, reason: str }
  type View = {
    windows: int, focus: str, modifiable: bool, line: int, column: int,
    atOrigin: bool, folded: List[str], definitionRequests: int, notices: List[Notice]
  }
  type Session = {
    request: Request, phase: str, sourceRevision: int, graphRevision: int, edit: str,
    yesFolded: bool, view: View
  }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val closeBranchRequest = { op: "closeYesBranch", arg: "" }
  pure val selectRequest = { op: "positionOnCondition", arg: "allowed" }
  pure val diskEditRequest = { op: "editSource", arg: "disk" }
  pure val bufferEditRequest = { op: "editSource", arg: "buffer" }
  pure val followRequest = { op: "followDefinition", arg: "" }
  pure val backRequest = { op: "back", arg: "" }
  pure val reloadRequest = { op: "reloadSource", arg: "" }
  pure val requests = Set(showRequest, closeBranchRequest, selectRequest, diskEditRequest, bufferEditRequest,
    followRequest, backRequest, reloadRequest)

  pure val staleWarning = { level: "warn", reason: "staleGraph" }
  pure def sourceView(line: int, column: int): View = {
    windows: 1, focus: "source", modifiable: true, line: line, column: column,
    atOrigin: false, folded: List(), definitionRequests: 0, notices: List()
  }
  // Graph coordinates are presentation details. atOrigin denotes the actual buffer
  // and exact cursor put on the guard occurrence by positionOnCondition.
  pure def graphView(atOrigin: bool, yesFolded: bool): View = {
    windows: 1, focus: "graph", modifiable: false, line: 0, column: 0,
    atOrigin: atOrigin, folded: if (yesFolded) List("Yes") else List(),
    definitionRequests: 0, notices: List()
  }

  action init = session' = {
    request: initRequest, phase: "source", sourceRevision: 0, graphRevision: 0,
    edit: "none", yesFolded: false, view: sourceView(1, 0),
  }

  action showGraph = all {
    session.phase == "source",
    session' = { ...session, request: showRequest, phase: "graph",
      graphRevision: session.sourceRevision, yesFolded: false, view: graphView(false, false) },
  }

  action closeYesBranch = all {
    session.phase == "graph",
    not(session.yesFolded),
    session' = { ...session, request: closeBranchRequest, yesFolded: true, view: graphView(false, true) },
  }

  action positionOnCondition = all {
    session.phase == "graph",
    session' = { ...session, request: selectRequest, phase: "condition",
      view: graphView(true, session.yesFolded) },
  }

  action editSource(request: Request): bool = all {
    session.phase == "condition",
    session.sourceRevision == 0,
    Set(diskEditRequest, bufferEditRequest).contains(request),
    session' = { ...session, request: request, sourceRevision: 1, edit: request.arg },
  }

  val fresh = session.graphRevision == session.sourceRevision
  // A disk edit inserts one line before the definition. Follow requests are
  // observed to completion, not while the language server is preparing a reply.
  pure def allowedDefinition(revision: int): View = {
    ...sourceView(9 + revision, 8), definitionRequests: 1
  }

  action followDefinition = all {
    session.phase == "condition",
    session' = if (fresh) {
      ...session, request: followRequest, phase: "definition", view: allowedDefinition(session.sourceRevision)
    } else {
      ...session, request: followRequest, phase: "rejected",
      view: { ...session.view, notices: List(staleWarning) }
    },
  }

  action back = all {
    session.phase == "definition",
    session' = { ...session, request: backRequest, phase: "returned", view: graphView(true, session.yesFolded) },
  }

  action reloadSource = all {
    session.phase == "rejected",
    session.edit == "disk",
    session' = { ...session, request: reloadRequest, phase: "source", view: sourceView(1, 0) },
  }

  action perform(request: Request): bool = any {
    all { request == showRequest, showGraph },
    all { request == closeBranchRequest, closeYesBranch },
    all { request == selectRequest, positionOnCondition },
    all { Set(diskEditRequest, bufferEditRequest).contains(request), editSource(request) },
    all { request == followRequest, followDefinition },
    all { request == backRequest, back },
    all { request == reloadRequest, reloadSource },
  }

  action step = any {
    {
      nondet request = requests.oneOf()
      perform(request)
    },
    all { session.phase == "returned" or (session.phase == "rejected" and session.edit == "buffer"), session' = session },
  }

  def observationMatches(observed: View): bool = session.view == observed

  val singleWindow = session.view.windows == 1
  val graphIsReadOnly = (session.view.focus == "graph") == not(session.view.modifiable)
  val freshFollowReachesDefinition = (session.request == followRequest and fresh) implies
    session.view == allowedDefinition(session.sourceRevision)
  val staleFollowKeepsOrigin = (session.request == followRequest and not(fresh)) implies all {
    session.view == { ...graphView(true, session.yesFolded), notices: List(staleWarning) },
  }
  val backRestoresOrigin = (session.request == backRequest) implies session.view == graphView(true, session.yesFolded)
  val closeYesBranchKeepsGraph = (session.request == closeBranchRequest) implies session.view == graphView(false, true)

  run freshDefinitionAndBackTest = init
    .then(perform(showRequest))
    .then(perform(closeBranchRequest))
    .expect(closeYesBranchKeepsGraph)
    .then(perform(selectRequest))
    .then(perform(followRequest))
    .expect(session.view.line == 9 and session.view.column == 8 and freshFollowReachesDefinition)
    .then(perform(backRequest))
    .expect(backRestoresOrigin and session.view.atOrigin and session.view.folded == List("Yes"))

  run dirtySourceRefusesDefinitionTest = init
    .then(perform(showRequest))
    .then(perform(selectRequest))
    .then(perform(bufferEditRequest))
    .then(perform(followRequest))
    .expect(session.phase == "rejected" and staleFollowKeepsOrigin)

  run diskChangeAndRegenerateTest = init
    .then(perform(showRequest))
    .then(perform(selectRequest))
    .then(perform(diskEditRequest))
    .then(perform(followRequest))
    .expect(session.phase == "rejected" and staleFollowKeepsOrigin)
    .then(perform(reloadRequest))
    .then(perform(showRequest))
    .then(perform(selectRequest))
    .then(perform(followRequest))
    .expect(session.view.line == 10 and session.view.column == 8 and freshFollowReachesDefinition)
    .then(perform(backRequest))
    .expect(backRestoresOrigin and session.view.atOrigin)
}
