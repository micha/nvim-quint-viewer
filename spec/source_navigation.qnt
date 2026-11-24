// Current viewer contract for following a Definition link in examples/approval.qnt.
module source_navigation {
  type Request = { op: str, arg: str }
  type Destination = { file: str, line: int, column: int }
  type Notice = { level: str, reason: str }
  // Pane roles in sorted order (including duplicates), not physical split order.
  // Notices are notifications from the last request, not inspector text.
  type View = {
    panes: List[str], focus: str, selected: str, destination: Destination, notices: List[Notice]
  }
  type Session = { request: Request, sourceChanged: bool, view: View }
  var session: Session

  pure val viewerPanes = List("graph", "inspector")
  pure val allowed = "approval.review.allowed"
  pure val mayApprove = "approval.mayApprove"
  pure val changedWarning = { level: "warn", reason: "sourceChanged" }
  pure val noDestination = { file: "", line: 0, column: 0 }

  pure val initRequest = { op: "init", arg: "" }
  pure val openRequest = { op: "openArtifact", arg: "" }
  pure def selectRequest(symbol: str): Request = { op: "selectSymbol", arg: symbol }
  pure val focusRequest = { op: "focusInspector", arg: "" }
  pure val editRequest = { op: "editSource", arg: "" }
  pure val followRequest = { op: "followDefinitionLink", arg: "" }
  pure val requests = Set(openRequest, selectRequest(allowed), selectRequest(mayApprove),
    focusRequest, editRequest, followRequest)

  // The two Definition links in the approval fixture point at distinct lines.
  pure def definition(symbol: str): Destination = {
    file: "approval.qnt", line: if (symbol == allowed) 9 else 5, column: 0
  }

  action init = session' = {
    request: initRequest,
    sourceChanged: false,
    view: { panes: List("editor"), focus: "editor", selected: "", destination: noDestination, notices: List() },
  }

  action record(request: Request, sourceChanged: bool, view: View): bool =
    session' = { request: request, sourceChanged: sourceChanged, view: view }

  action openArtifact = all {
    session.request == initRequest,
    record(openRequest, false, { ...session.view, panes: viewerPanes, focus: "graph" }),
  }

  action selectSymbol(symbol) = all {
    session.view.focus == "graph",
    session.view.selected == "",
    Set(allowed, mayApprove).contains(symbol),
    record(selectRequest(symbol), session.sourceChanged, { ...session.view, selected: symbol }),
  }

  action focusInspector = all {
    session.view.focus == "graph",
    session.view.selected != "",
    record(focusRequest, session.sourceChanged, { ...session.view, focus: "inspector" }),
  }

  val followed = session.request == followRequest

  action editSource = all {
    session.view.panes == viewerPanes,
    not(session.sourceChanged),
    not(followed),
    // The filesystem edit changes the input to the jump, not the visible view.
    record(editRequest, true, session.view),
  }

  action followDefinitionLink = all {
    session.view.focus == "inspector",
    not(followed),
    val view = session.view
    record(followRequest, session.sourceChanged,
      if (session.sourceChanged) { ...view, notices: List(changedWarning) }
      else { ...view, panes: view.panes.append("source"), focus: "source", destination: definition(view.selected) }),
  }

  // Model checking, named histories, and observation checks share this dispatch.
  action perform(request: Request): bool = any {
    all { request == openRequest, openArtifact },
    all { request == selectRequest(request.arg), selectSymbol(request.arg) },
    all { request == focusRequest, focusInspector },
    all { request == editRequest, editSource },
    all { request == followRequest, followDefinitionLink },
  }

  // One attempt per session. Terminal states can stutter for model checking.
  action step = any {
    {
      nondet request = requests.oneOf()
      perform(request)
    },
    all { followed, session' = session },
  }

  def observationMatches(observed: View): bool = session.view == observed

  val sourceOnlyAfterFreshFollow =
    (session.view.panes.foldl(false, (found, pane) => found or pane == "source") or session.view.focus == "source"
      or session.view.destination != noDestination)
      implies (followed and not(session.sourceChanged))

  val noticeOnlyAfterChangedFollow =
    (session.view.notices != List()) implies (followed and session.sourceChanged)

  val freshFollowOpensDefinition =
    (followed and not(session.sourceChanged)) implies all {
      session.view.panes == List("graph", "inspector", "source"),
      session.view.focus == "source",
      session.view.destination == definition(session.view.selected),
      session.view.notices == List(),
    }

  val changedFollowKeepsViewer =
    (followed and session.sourceChanged) implies all {
      session.view.panes == viewerPanes,
      session.view.focus == "inspector",
      session.view.destination == noDestination,
      session.view.notices == List(changedWarning),
    }

  run freshLocalDefinitionTest = init
    .then(perform(openRequest))
    .then(perform(selectRequest(allowed)))
    .then(perform(focusRequest))
    .then(perform(followRequest))
    .expect(followed and not(session.sourceChanged) and freshFollowOpensDefinition
      and session.view.destination == { file: "approval.qnt", line: 9, column: 0 })

  run freshOperatorDefinitionTest = init
    .then(perform(openRequest))
    .then(perform(selectRequest(mayApprove)))
    .then(perform(focusRequest))
    .then(perform(followRequest))
    .expect(followed and not(session.sourceChanged) and freshFollowOpensDefinition
      and session.view.destination == { file: "approval.qnt", line: 5, column: 0 })

  run changedAfterOpenTest = init
    .then(perform(openRequest))
    .then(perform(selectRequest(allowed)))
    .then(perform(focusRequest))
    .then(perform(editRequest))
    .then(perform(followRequest))
    .expect(followed and session.sourceChanged and changedFollowKeepsViewer and session.view.selected == allowed)
}
