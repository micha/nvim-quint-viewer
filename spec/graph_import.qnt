// Same-spelled definitions in the caller and its imported policy module.
module graph_import {
  type Request = { op: str, arg: str }
  type Notice = { level: str, reason: str }
  type View = {
    windows: int, focus: str, modifiable: bool, line: int, column: int,
    atOrigin: bool, definitionRequests: int, notices: List[Notice]
  }
  type Session = {
    request: Request, phase: str, selected: str, callerEdited: bool,
    policyEdit: str, graphUsesMovedPolicy: bool, serverUsesMovedPolicy: bool, view: View,
  }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val selectImport = { op: "positionOnCall", arg: "remote::allowed" }
  pure val selectLocal = { op: "positionOnCall", arg: "allowed" }
  pure val editRequest = { op: "editCaller", arg: "" }
  pure val editPolicyDiskRequest = { op: "editPolicyDisk", arg: "" }
  pure val editPolicyBufferRequest = { op: "editPolicyBuffer", arg: "" }
  pure val followRequest = { op: "followDefinition", arg: "" }
  pure val backRequest = { op: "back", arg: "" }
  pure val returnToCallerRequest = { op: "returnToCaller", arg: "" }
  pure val reanalyzeCallerRequest = { op: "reanalyzeCaller", arg: "" }
  pure val calls = Set(selectImport, selectLocal)
  pure val requests = calls.union(Set(showRequest, editRequest, editPolicyDiskRequest,
    editPolicyBufferRequest, followRequest, backRequest, returnToCallerRequest, reanalyzeCallerRequest))

  // Source focus denotes the exact fixture path, never just its basename.
  pure def sourceView(file: str, line: int, column: int): View = {
    windows: 1, focus: file, modifiable: true, line: line, column: column,
    atOrigin: false, definitionRequests: 0, notices: List(),
  }
  // Graph coordinates are presentation details; atOrigin requires the original
  // window, graph buffer, and exact cursor chosen by positionOnCall.
  pure def graphView(atOrigin: bool): View = {
    windows: 1, focus: "graph", modifiable: false, line: 0, column: 0,
    atOrigin: atOrigin, definitionRequests: 0, notices: List(),
  }
  pure def definitionView(selected: str, moved: bool): View = {
    ...(if (selected == selectImport.arg) sourceView("policy.qnt", if (moved) 4 else 2, 0)
      else sourceView("caller.qnt", 3, 11)),
    definitionRequests: 1,
  }
  pure val rejectedView = { ...graphView(true), notices: List({ level: "warn", reason: "staleGraph" }) }
  pure val rejectedReplyView = {
    ...graphView(true), definitionRequests: 1, notices: List({ level: "warn", reason: "staleDefinition" }),
  }
  pure val callerView = sourceView("caller.qnt", 1, 0)

  action init = session' = {
    request: initRequest, phase: "source", selected: "", callerEdited: false,
    policyEdit: "none", graphUsesMovedPolicy: false, serverUsesMovedPolicy: false, view: callerView,
  }
  action showGraph = all {
    session.phase == "source",
    session' = {
      ...session, request: showRequest, phase: "graph", graphUsesMovedPolicy: session.policyEdit == "disk",
      view: graphView(false),
    },
  }
  action positionOnCall(request: Request): bool = all {
    session.phase == "graph",
    calls.contains(request),
    session' = { ...session, request: request, phase: "call", selected: request.arg, view: graphView(true) },
  }
  action editCaller = all {
    session.phase == "call",
    not(session.callerEdited),
    session.policyEdit == "none",
    session' = { ...session, request: editRequest, callerEdited: true },
  }
  action editPolicy(request: Request, kind: str): bool = all {
    session.phase == "call",
    not(session.callerEdited),
    session.policyEdit == "none",
    session' = { ...session, request: request, policyEdit: kind },
  }
  val importedCall = session.selected == selectImport.arg
  val staleGraph = session.callerEdited or (importedCall and
    (session.policyEdit == "buffer" or (session.policyEdit == "disk" and not(session.graphUsesMovedPolicy))))
  val staleReply = importedCall and (session.graphUsesMovedPolicy != session.serverUsesMovedPolicy)
  action followDefinition = all {
    session.phase == "call",
    session' = if (staleGraph) {
      ...session, request: followRequest, phase: "rejected", view: rejectedView,
    } else if (staleReply) {
      ...session, request: followRequest, phase: "rejected", view: rejectedReplyView,
    } else {
      ...session, request: followRequest, phase: "definition",
      view: definitionView(session.selected, session.policyEdit == "disk"),
    },
  }
  action returnToCaller = all {
    session.phase == "rejected",
    session.policyEdit == "disk",
    session' = { ...session, request: returnToCallerRequest, phase: "source", view: callerView },
  }
  action reanalyzeCaller = all {
    session.phase == "source",
    session.policyEdit == "disk",
    not(session.serverUsesMovedPolicy),
    session' = { ...session, request: reanalyzeCallerRequest, serverUsesMovedPolicy: true, view: callerView },
  }
  action back = all {
    session.phase == "definition",
    session' = { ...session, request: backRequest, phase: "returned", view: graphView(true) },
  }

  action perform(request: Request): bool = any {
    all { request == showRequest, showGraph },
    all { calls.contains(request), positionOnCall(request) },
    all { request == editRequest, editCaller },
    all { request == editPolicyDiskRequest, editPolicy(request, "disk") },
    all { request == editPolicyBufferRequest, editPolicy(request, "buffer") },
    all { request == followRequest, followDefinition },
    all { request == backRequest, back },
    all { request == returnToCallerRequest, returnToCaller },
    all { request == reanalyzeCallerRequest, reanalyzeCaller },
  }
  action step = any {
    { nondet request = requests.oneOf(); perform(request) },
    all { Set("returned", "rejected").contains(session.phase), session' = session },
  }

  // For an unopened imported file the upstream server owns placement within
  // the declaration line. Its selected column is not part of this contract.
  def observationMatches(observed: View): bool =
    if (session.phase == "definition" and session.selected == selectImport.arg)
      session.view == { ...observed, column: 0 }
    else session.view == observed
  val singleWindow = session.view.windows == 1
  val graphIsReadOnly = (session.view.focus == "graph") == not(session.view.modifiable)
  val freshFollowResolvesScope = (session.request == followRequest and not(staleGraph) and not(staleReply)) implies all {
    session.view.definitionRequests == 1,
    importedCall implies (session.view.focus == "policy.qnt" and session.view.line ==
      (if (session.policyEdit == "disk") 4 else 2)),
    not(importedCall) implies (session.view.focus == "caller.qnt" and session.view.line == 3 and session.view.column == 11),
  }
  val staleGraphWarnsWithoutRequest = (session.request == followRequest and staleGraph) implies
    session.view == rejectedView
  val staleServerReplyDoesNotJump = (session.request == followRequest and not(staleGraph) and staleReply) implies
    session.view == rejectedReplyView
  val backRestoresOrigin = (session.request == backRequest) implies session.view == graphView(true)

  run importedDefinitionAndBackTest = init
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(followRequest))
    .expect(freshFollowResolvesScope and session.view.focus == "policy.qnt" and session.view.line == 2)
    .then(perform(backRequest))
    .expect(backRestoresOrigin)

  run localDefinitionAndBackTest = init
    .then(perform(showRequest))
    .then(perform(selectLocal))
    .then(perform(followRequest))
    .expect(freshFollowResolvesScope and session.view.line == 3 and session.view.column == 11)
    .then(perform(backRequest))
    .expect(backRestoresOrigin)

  run dirtyCallerRefusesImportedDefinitionTest = init
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(editRequest))
    .then(perform(followRequest))
    .expect(session.phase == "rejected" and staleGraphWarnsWithoutRequest)

  run movedPolicyRefusesImportedDefinitionTest = init
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(editPolicyDiskRequest))
    .then(perform(followRequest))
    .expect(session.view == rejectedView)

  run dirtyPolicyRefusesImportedDefinitionTest = init
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(editPolicyBufferRequest))
    .then(perform(followRequest))
    .expect(session.view == rejectedView)

  run movedPolicyDoesNotBlockLocalDefinitionTest = init
    .then(perform(showRequest))
    .then(perform(selectLocal))
    .then(perform(editPolicyDiskRequest))
    .then(perform(followRequest))
    .expect(freshFollowResolvesScope and session.view.focus == "caller.qnt" and session.view.line == 3)
    .then(perform(backRequest))
    .expect(backRestoresOrigin)

  run movedPolicyRefreshTest = init
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(editPolicyDiskRequest))
    .then(perform(followRequest))
    .expect(session.view == rejectedView)
    .then(perform(returnToCallerRequest))
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(followRequest))
    .expect(session.view == rejectedReplyView)
    .then(perform(returnToCallerRequest))
    .then(perform(reanalyzeCallerRequest))
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(followRequest))
    .expect(freshFollowResolvesScope and session.view.focus == "policy.qnt" and session.view.line == 4)
    .then(perform(backRequest))
    .expect(backRestoresOrigin)
}
