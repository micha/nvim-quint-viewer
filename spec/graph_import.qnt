// Same-spelled definitions in the caller and its imported policy module.
module graph_import {
  type Request = { op: str, arg: str }
  type Notice = { level: str, reason: str }
  type Position = { file: str, line: int, column: int }
  type View = {
    windows: int, focus: str, modifiable: bool, line: int, column: int,
    atOrigin: bool, definitionRequests: int, notices: List[Notice]
  }
  type Session = {
    request: Request, phase: str, selected: str, callerEdited: bool,
    policyEdit: str, graphPolicyVersion: str, serverPolicyVersion: str, view: View,
  }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val selectImport = { op: "positionOnCall", arg: "remote::allowed" }
  pure val selectLocal = { op: "positionOnCall", arg: "allowed" }
  pure val editRequest = { op: "editCaller", arg: "" }
  pure val editPolicyDiskRequest = { op: "editPolicyDisk", arg: "" }
  pure val shiftPolicyColumnRequest = { op: "shiftPolicyColumn", arg: "" }
  pure val editPolicyBufferRequest = { op: "editPolicyBuffer", arg: "" }
  pure val followRequest = { op: "followDefinition", arg: "" }
  pure val backRequest = { op: "back", arg: "" }
  pure val returnToCallerRequest = { op: "returnToCaller", arg: "" }
  pure val reanalyzeCallerRequest = { op: "reanalyzeCaller", arg: "" }
  pure val calls = Set(selectImport, selectLocal)
  pure val requests = calls.union(Set(showRequest, editRequest, editPolicyDiskRequest, shiftPolicyColumnRequest,
    editPolicyBufferRequest, followRequest, backRequest, returnToCallerRequest, reanalyzeCallerRequest))

  // Source positions use one-based lines and zero-based byte columns.
  // File identities denote exact fixture paths, not just matching basenames.
  pure def policyVersion(edit: str): str = if (Set("line", "column").contains(edit)) edit else "original"
  // The same-line shift inserts a declaration with a multibyte character
  // before allowed; the server's UTF-16 column 33 is byte column 34.
  pure def policyDeclaration(version: str): Position = {
    file: "policy.qnt", line: if (version == "line") 4 else 2, column: if (version == "column") 34 else 11,
  }
  pure val localDeclaration = { file: "caller.qnt", line: 3, column: 11 }
  pure def sourceView(position: Position): View = {
    windows: 1, focus: position.file, modifiable: true, line: position.line, column: position.column,
    atOrigin: false, definitionRequests: 0, notices: List(),
  }
  // Graph coordinates are presentation details; atOrigin requires the original
  // window, graph buffer, and exact cursor chosen by positionOnCall.
  pure def graphView(atOrigin: bool): View = {
    windows: 1, focus: "graph", modifiable: false, line: 0, column: 0,
    atOrigin: atOrigin, definitionRequests: 0, notices: List(),
  }
  pure def definitionView(position: Position): View = { ...sourceView(position), definitionRequests: 1 }
  pure val rejectedView = { ...graphView(true), notices: List({ level: "warn", reason: "staleGraph" }) }
  pure val rejectedReplyView = {
    ...graphView(true), definitionRequests: 1, notices: List({ level: "warn", reason: "staleDefinition" }),
  }
  pure val callerView = sourceView({ file: "caller.qnt", line: 1, column: 0 })
  val diskVersion = policyVersion(session.policyEdit)

  action init = session' = {
    request: initRequest, phase: "source", selected: "", callerEdited: false,
    policyEdit: "none", graphPolicyVersion: "original", serverPolicyVersion: "original", view: callerView,
  }
  action showGraph = all {
    session.phase == "source",
    session' = {
      ...session, request: showRequest, phase: "graph", graphPolicyVersion: diskVersion, view: graphView(false),
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
    (session.policyEdit == "buffer" or session.graphPolicyVersion != diskVersion))
  val graphDeclaration = policyDeclaration(session.graphPolicyVersion)
  val definitionReply = if (importedCall) policyDeclaration(session.serverPolicyVersion) else localDeclaration
  action followDefinition = all {
    session.phase == "call",
    session' = if (staleGraph) {
      ...session, request: followRequest, phase: "rejected", view: rejectedView,
    } else if (importedCall and definitionReply != graphDeclaration) {
      ...session, request: followRequest, phase: "rejected", view: rejectedReplyView,
    } else {
      ...session, request: followRequest, phase: "definition", view: definitionView(definitionReply),
    },
  }
  action returnToCaller = all {
    session.phase == "rejected",
    diskVersion != "original",
    session' = { ...session, request: returnToCallerRequest, phase: "source", view: callerView },
  }
  action reanalyzeCaller = all {
    session.phase == "source",
    session.serverPolicyVersion != diskVersion,
    session' = { ...session, request: reanalyzeCallerRequest, serverPolicyVersion: diskVersion, view: callerView },
  }
  action back = all {
    session.phase == "definition",
    session' = { ...session, request: backRequest, phase: "returned", view: graphView(true) },
  }

  action perform(request: Request): bool = any {
    all { request == showRequest, showGraph },
    all { calls.contains(request), positionOnCall(request) },
    all { request == editRequest, editCaller },
    all { request == editPolicyDiskRequest, editPolicy(request, "line") },
    all { request == shiftPolicyColumnRequest, editPolicy(request, "column") },
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

  def observationMatches(observed: View): bool = session.view == observed
  val singleWindow = session.view.windows == 1
  val graphIsReadOnly = (session.view.focus == "graph") == not(session.view.modifiable)
  val serverAndGraphDisagree = importedCall and session.graphPolicyVersion != session.serverPolicyVersion
  val freshFollowResolvesScope = (session.request == followRequest and not(staleGraph) and not(serverAndGraphDisagree)) implies
    session.view == definitionView(if (importedCall) policyDeclaration(diskVersion) else localDeclaration)
  val staleGraphWarnsWithoutRequest = (session.request == followRequest and staleGraph) implies
    session.view == rejectedView
  val staleServerReplyDoesNotJump = (session.request == followRequest and not(staleGraph) and serverAndGraphDisagree) implies
    session.view == rejectedReplyView
  val backRestoresOrigin = (session.request == backRequest) implies session.view == graphView(true)

  run importedDefinitionAndBackTest = init
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(followRequest))
    .expect(freshFollowResolvesScope and session.view == definitionView({ file: "policy.qnt", line: 2, column: 11 }))
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
    .expect(freshFollowResolvesScope and session.view == definitionView({ file: "policy.qnt", line: 4, column: 11 }))
    .then(perform(backRequest))
    .expect(backRestoresOrigin)

  run shiftedPolicyRefreshTest = init
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(shiftPolicyColumnRequest))
    .then(perform(followRequest))
    .expect(session.view == rejectedView)
    .then(perform(returnToCallerRequest))
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(followRequest))
    .expect(definitionReply.file == graphDeclaration.file and definitionReply.line == graphDeclaration.line and
      definitionReply.column != graphDeclaration.column and session.view == rejectedReplyView)
    .then(perform(returnToCallerRequest))
    .then(perform(reanalyzeCallerRequest))
    .then(perform(showRequest))
    .then(perform(selectImport))
    .then(perform(followRequest))
    .expect(freshFollowResolvesScope and session.view == definitionView({ file: "policy.qnt", line: 2, column: 34 }))
    .then(perform(backRequest))
    .expect(backRestoresOrigin)
}
