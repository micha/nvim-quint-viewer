// Definition navigation in tests/fixtures/graph_definition_mode. The two
// modules intentionally define the same name, but their graphs differ.
module graph_definition_mode {
  type Request = { op: str, arg: str }
  type Notice = { level: str, reason: str }
  type Position = { line: int, column: int }
  type Lookup = { method: str, file: str, position: Position }
  type View = {
    windows: int, sameWindow: bool, focus: str, modifiable: bool, position: Position,
    atOrigin: bool, atTarget: bool, historyChanged: bool,
    heldReply: bool, lookups: List[Lookup], notices: List[Notice]
  }
  type Session = { request: Request, phase: str, occurrence: str, edit: str, mode: str, view: View }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "review" }
  pure val localCall = { op: "selectOccurrence", arg: "allowed" }
  pure val importedCall = { op: "selectOccurrence", arg: "remote::allowed" }
  pure val parameter = { op: "selectOccurrence", arg: "input" }
  pure val binding = { op: "selectOccurrence", arg: "permitted" }
  pure val helperCall = { op: "selectOccurrence", arg: "helper" }
  pure val selections = Set(localCall, importedCall, parameter, binding, helperCall)
  pure val dirtyCaller = { op: "editSource", arg: "callerBuffer" }
  pure val movedPolicy = { op: "editSource", arg: "policyDisk" }
  pure val edits = Set(dirtyCaller, movedPolicy)
  pure val graphRequest = { op: "pressDefinition", arg: "gd" }
  pure val rawRequest = { op: "pressDefinition", arg: "gD" }
  pure val deliverRequest = { op: "deliverReply", arg: "matching" }
  pure val wrongReply = { op: "deliverReply", arg: "wrongScope" }
  pure val backRequest = { op: "back", arg: "" }
  pure val forwardRequest = { op: "forward", arg: "" }
  pure val sourceSelect = { op: "selectSourceCall", arg: "allowed" }
  pure val sourceFollow = { op: "pressSourceGd", arg: "" }
  pure val toggleRequest = { op: "toggleView", arg: "" }
  pure val revisitRequest = { op: "revisitGraph", arg: "" }
  pure val requests = selections.union(edits).union(Set(showRequest, graphRequest, rawRequest,
    deliverRequest, wrongReply, backRequest, forwardRequest, sourceSelect, sourceFollow,
    toggleRequest, revisitRequest))

  pure val staleGraph = { level: "warn", reason: "staleGraph" }
  pure val staleDefinition = { level: "warn", reason: "staleDefinition" }
  pure val useRaw = { level: "warn", reason: "noGraphUseRaw" }
  pure val sourceView: View = {
    windows: 1, sameWindow: true, focus: "caller.qnt", modifiable: true, position: { line: 1, column: 0 },
    atOrigin: false, atTarget: false, historyChanged: false, heldReply: false, lookups: List(), notices: List()
  }
  pure val reviewView = { ...sourceView, focus: "caller:review", modifiable: false }
  // Rows are one-based and columns are zero-based bytes for editor cursors.
  pure def origin(occurrence: str): View = { ...reviewView, atOrigin: true,
    focus: if (occurrence == "helper") "policy:allowed" else reviewView.focus,
    position: if (occurrence == "helper") { line: 5, column: 7 }
      else if (occurrence == "remote::allowed") { line: 6, column: 19 }
      else if (occurrence == "allowed") { line: 8, column: 13 }
      else if (occurrence == "input") { line: 5, column: 18 }
      else { line: 6, column: 29 }
  }
  // LSP uses zero-based rows and UTF-16 columns; these occurrence lines are ASCII.
  pure def occurrenceLookup(occurrence: str): Lookup = { method: "definition",
    file: if (occurrence == "helper") "policy.qnt" else "caller.qnt",
    position: if (occurrence == "helper") { line: 1, column: 37 }
      else if (occurrence == "remote::allowed") { line: 6, column: 8 }
      else if (occurrence == "allowed") { line: 6, column: 36 }
      else if (occurrence == "input") { line: 5, column: 20 }
      else { line: 6, column: 24 }
  }
  pure def rawTarget(occurrence: str): View = { ...sourceView, atTarget: true, historyChanged: true,
    focus: if (occurrence == "remote::allowed") "policy.qnt" else "caller.qnt",
    position: if (occurrence == "remote::allowed") { line: 2, column: 11 }
      else if (occurrence == "allowed") { line: 3, column: 11 }
      else if (occurrence == "input") { line: 5, column: 18 }
      else { line: 6, column: 8 }
  }
  pure def graphTarget(occurrence: str): View = { ...reviewView, atTarget: true, historyChanged: true,
    focus: if (occurrence == "helper") "policy:helper"
      else if (occurrence == "remote::allowed") "policy:allowed" else "caller:allowed",
    position: { line: 4, column: 0 }
  }
  pure def target(mode: str, occurrence: str): View =
    if (mode == "gd") graphTarget(occurrence) else rawTarget(occurrence)

  pure def graphBacking(occurrence: str): View =
    if (occurrence == "helper") { ...sourceView, focus: "policy.qnt", position: { line: 3, column: 11 } }
    else { ...rawTarget(occurrence), atTarget: false, historyChanged: false }

  val atOrigin = origin(session.occurrence)
  val destination = target(session.mode, session.occurrence)
  val secondHop = session.occurrence == "helper"
  val renderable = Set("allowed", "remote::allowed", "helper").contains(session.occurrence)
  pure val chainStart = { ...origin("remote::allowed"), historyChanged: true }
  val fresh = session.edit != "callerBuffer" and
    (session.occurrence != "remote::allowed" or session.edit != "policyDisk")
  val followKey = Set(graphRequest, rawRequest).contains(session.request)
  val replyArrival = Set(deliverRequest, wrongReply).contains(session.request)

  action init = session' = {
    request: initRequest, phase: "source", occurrence: "", edit: "", mode: "", view: sourceView
  }
  action showGraph = all {
    session.phase == "source",
    session' = { ...session, request: showRequest, phase: "graph", view: reviewView }
  }
  action selectOccurrence(request: Request): bool = all {
    selections.contains(request),
    if (request == helperCall) {
      session.phase == "target" and session.mode == "gd" and session.occurrence == "remote::allowed"
    } else { session.phase == "graph" },
    session' = { ...session, request: request, phase: "origin", occurrence: request.arg, view: origin(request.arg) }
  }
  // Fresh graph-to-graph chaining is the only bounded second-hop case.
  action editSource(request: Request): bool = all {
    Set("origin", "waiting").contains(session.phase),
    session.edit == "" and not(secondHop),
    edits.contains(request),
    session' = { ...session, request: request, edit: request.arg, view: { ...session.view, lookups: List() } }
  }
  action pressDefinition(request: Request): bool = all {
    session.phase == "origin" or (session.phase == "advised" and request == rawRequest),
    Set(graphRequest, rawRequest).contains(request),
    secondHop implies request == graphRequest,
    session' = if (not(fresh)) {
      ...session, request: request, mode: request.arg, phase: "rejected",
      view: { ...atOrigin, notices: List(staleGraph) }
    } else if (request == graphRequest and not(renderable)) {
      ...session, request: request, mode: request.arg, phase: "advised",
      view: { ...atOrigin, notices: List(useRaw) }
    } else {
      ...session, request: request, mode: request.arg, phase: "waiting",
      view: { ...atOrigin, heldReply: true, lookups: List(occurrenceLookup(session.occurrence)) }
    }
  }
  action deliverReply(request: Request): bool = all {
    session.phase == "waiting",
    request == deliverRequest or (request == wrongReply and session.mode == "gd" and
      session.occurrence == "remote::allowed" and fresh),
    session' = if (not(fresh)) {
      ...session, request: request, phase: "rejected", view: { ...atOrigin, notices: List(staleGraph) }
    } else if (request == wrongReply) {
      ...session, request: request, phase: "rejected", view: { ...atOrigin, notices: List(staleDefinition) }
    } else {
      ...session, request: request, phase: "target", view: destination
    }
  }
  val backAtOrigin = { ...atOrigin, historyChanged: true }
  action back = all {
    session.phase == "target" or (secondHop and session.phase == "back"),
    session' = if (session.phase == "target") {
      ...session, request: backRequest, phase: "back", view: backAtOrigin
    } else {
      ...session, request: backRequest, phase: "chainStart", view: chainStart
    }
  }
  action forward = all {
    Set("chainStart", "back").contains(session.phase),
    session' = if (session.phase == "chainStart") {
      ...session, request: forwardRequest, phase: "back", view: backAtOrigin
    } else {
      ...session, request: forwardRequest, phase: "target", view: destination
    }
  }
  action toggleView = any {
    all {
      session.phase == "target", session.mode == "gd",
      session' = { ...session, request: toggleRequest, phase: "toggled", view: graphBacking(session.occurrence) },
    },
    all {
      // One pending reply held while leaving, then revisiting the same site.
      session.phase == "waiting", session.mode == "gd", session.edit == "", session.occurrence == "allowed",
      session' = { ...session, request: toggleRequest, phase: "toggledWhileWaiting",
        view: { ...sourceView, heldReply: true } },
    },
  }
  action revisitGraph = all {
    session.phase == "toggledWhileWaiting",
    session' = { ...session, request: revisitRequest, phase: "revisited", view: { ...atOrigin, heldReply: true } },
  }
  action ignoreCanceledReply = all {
    session.phase == "revisited",
    session' = { ...session, request: deliverRequest, phase: "canceled", view: atOrigin },
  }
  // A user's existing source-buffer LSP map is outside the viewer, but must
  // still land in source after a graph gD has returned to that buffer.
  action selectSourceCall = all {
    session.phase == "target",
    session.mode == "gD" and session.occurrence == "input" and session.edit == "",
    session' = { ...session, request: sourceSelect, phase: "sourceCall",
      view: { ...sourceView, position: { line: 7, column: 36 } } },
  }
  pure val sourceDefinition = { ...sourceView, position: { line: 3, column: 11 },
    historyChanged: true, lookups: List(occurrenceLookup("allowed")) }
  action followSource = all {
    session.phase == "sourceCall",
    session' = { ...session, request: sourceFollow, phase: "sourceDefinition", view: sourceDefinition },
  }
  action perform(request: Request): bool = any {
    all { request == showRequest, showGraph },
    all { selections.contains(request), selectOccurrence(request) },
    all { edits.contains(request), editSource(request) },
    all { Set(graphRequest, rawRequest).contains(request), pressDefinition(request) },
    all { Set(deliverRequest, wrongReply).contains(request), deliverReply(request) },
    all { request == backRequest, back },
    all { request == forwardRequest, forward },
    all { request == sourceSelect, selectSourceCall },
    all { request == sourceFollow, followSource },
    all { request == toggleRequest, toggleView },
    all { request == revisitRequest, revisitGraph },
    all { request == deliverRequest, ignoreCanceledReply },
  }
  action step = any {
    { nondet request = requests.oneOf() perform(request) },
    all { Set("advised", "rejected", "sourceDefinition", "toggled", "canceled").contains(session.phase), session' = session },
  }

  def observationMatches(observed: View): bool = session.view == observed

  val singleWindow = session.view.windows == 1 and session.view.sameWindow
  val onlySourceEditable = session.view.modifiable == Set("caller.qnt", "policy.qnt").contains(session.view.focus)
  val followWaitsAtOrigin = (followKey and fresh and (session.mode == "gD" or renderable)) implies
    session.view == { ...atOrigin, heldReply: true, lookups: List(occurrenceLookup(session.occurrence)) }
  val staleDefinitionKeepsOrigin = ((followKey or replyArrival) and not(fresh)) implies
    session.view == { ...atOrigin, notices: List(staleGraph) }
  val unrenderableOffersRaw = (session.request == graphRequest and fresh and not(renderable)) implies
    session.view == { ...atOrigin, notices: List(useRaw) }
  val wrongScopeKeepsOrigin = (session.request == wrongReply) implies
    session.view == { ...atOrigin, notices: List(staleDefinition) }
  val freshReplyPreservesMode = (session.request == deliverRequest and fresh and session.phase != "canceled") implies all {
    session.view == destination,
    (session.mode == "gd") implies renderable and not(session.view.modifiable),
    (session.mode == "gD") implies session.view.modifiable,
  }
  val exactNativeHistory = all {
    (session.request == backRequest) implies session.view ==
      (if (session.phase == "chainStart") chainStart else backAtOrigin),
    (session.request == forwardRequest) implies session.view ==
      (if (session.phase == "back") backAtOrigin else destination),
  }

  val rawGdRemainsInSource = (session.request == sourceFollow) implies session.view == sourceDefinition
  val toggleOpensBackingSource = session.request == toggleRequest implies session.view ==
    (if (session.phase == "toggledWhileWaiting") { ...sourceView, heldReply: true } else graphBacking(session.occurrence))
  val canceledReplyKeepsRevisitedGraph = session.phase == "canceled" implies session.view == atOrigin

  run toggleImportedGraphTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(graphRequest)).then(perform(deliverRequest)).expect(session.view.focus == "policy:allowed")
    .then(perform(toggleRequest)).expect(toggleOpensBackingSource and session.view.focus == "policy.qnt")
  run toggleCancelsPendingDefinitionTest = init.then(perform(showRequest)).then(perform(localCall))
    .then(perform(graphRequest)).expect(session.view.heldReply)
    .then(perform(toggleRequest)).expect(toggleOpensBackingSource and session.view.focus == "caller.qnt")
    .then(perform(revisitRequest)).expect(session.view.atOrigin and session.view.heldReply)
    .then(perform(deliverRequest)).expect(canceledReplyKeepsRevisitedGraph and not(session.view.heldReply))

  run localGraphAndHistoryTest = init.then(perform(showRequest)).then(perform(localCall))
    .then(perform(graphRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(deliverRequest)).expect(session.view.focus == "caller:allowed" and freshReplyPreservesMode)
    .then(perform(backRequest)).expect(exactNativeHistory and session.view.atOrigin)
    .then(perform(forwardRequest)).expect(exactNativeHistory and session.view.atTarget)
  run importedGraphAndHistoryTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(graphRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(deliverRequest)).expect(session.view.focus == "policy:allowed" and freshReplyPreservesMode)
    .then(perform(backRequest)).expect(exactNativeHistory and session.view.atOrigin)
    .then(perform(forwardRequest)).expect(exactNativeHistory and session.view.atTarget)
  run importedGraphSupportsSecondHopTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(graphRequest)).expect(session.view.heldReply)
    .then(perform(deliverRequest)).expect(session.view.focus == "policy:allowed")
    .then(perform(helperCall)).then(perform(graphRequest))
    .expect(session.view.heldReply and followWaitsAtOrigin and session.view.lookups == List({
      method: "definition", file: "policy.qnt", position: { line: 1, column: 37 }
    }))
    .then(perform(deliverRequest)).expect(session.view.focus == "policy:helper" and freshReplyPreservesMode)
    .then(perform(backRequest)).expect(session.view.focus == "policy:allowed" and exactNativeHistory)
    .then(perform(backRequest)).expect(session.view.focus == "caller:review" and exactNativeHistory)
    .then(perform(forwardRequest)).expect(session.view.focus == "policy:allowed" and exactNativeHistory)
    .then(perform(forwardRequest)).expect(session.view.focus == "policy:helper" and exactNativeHistory)
  run parameterAdvisesRawAndJumpsTest = init.then(perform(showRequest)).then(perform(parameter))
    .then(perform(graphRequest)).expect(session.phase == "advised" and unrenderableOffersRaw)
    .then(perform(rawRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(deliverRequest)).expect(session.view.position == { line: 5, column: 18 } and freshReplyPreservesMode)
    .then(perform(backRequest)).expect(exactNativeHistory and session.view.atOrigin)
  run bindingAdvisesRawAndJumpsTest = init.then(perform(showRequest)).then(perform(binding))
    .then(perform(graphRequest)).expect(session.phase == "advised" and unrenderableOffersRaw)
    .then(perform(rawRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(deliverRequest)).expect(session.view.position == { line: 6, column: 8 } and freshReplyPreservesMode)
  run rawSourceMapStillWorksTest = init.then(perform(showRequest)).then(perform(parameter))
    .then(perform(rawRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(deliverRequest)).expect(session.view.focus == "caller.qnt" and freshReplyPreservesMode)
    .then(perform(sourceSelect)).then(perform(sourceFollow)).expect(rawGdRemainsInSource and session.view.modifiable)
  run importedRawDefinitionTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(rawRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(deliverRequest)).expect(session.view.focus == "policy.qnt" and freshReplyPreservesMode)
    .then(perform(backRequest)).expect(exactNativeHistory and session.view.atOrigin)
  run staleGraphBeforeRequestTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(movedPolicy)).then(perform(graphRequest)).expect(session.phase == "rejected" and staleDefinitionKeepsOrigin)
  run staleCallerBeforeReplyTest = init.then(perform(showRequest)).then(perform(localCall))
    .then(perform(graphRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(dirtyCaller)).then(perform(deliverRequest)).expect(session.phase == "rejected" and staleDefinitionKeepsOrigin)
  run stalePolicyBeforeReplyTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(graphRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(movedPolicy)).then(perform(deliverRequest)).expect(session.phase == "rejected" and staleDefinitionKeepsOrigin)
  run stalePolicyBeforeRawReplyTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(rawRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(movedPolicy)).then(perform(deliverRequest)).expect(session.phase == "rejected" and staleDefinitionKeepsOrigin)
  run stalePolicyDoesNotAffectLocalGraphTest = init.then(perform(showRequest)).then(perform(localCall))
    .then(perform(graphRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(movedPolicy)).then(perform(deliverRequest))
    .expect(session.view.focus == "caller:allowed" and freshReplyPreservesMode)
  run wrongScopeReplyTest = init.then(perform(showRequest)).then(perform(importedCall))
    .then(perform(graphRequest)).expect(followWaitsAtOrigin and session.view.heldReply)
    .then(perform(wrongReply)).expect(session.phase == "rejected" and wrongScopeKeepsOrigin)
}
