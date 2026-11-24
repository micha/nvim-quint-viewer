// Public :QuintView behavior from tests/fixtures/graph_selection.qnt.
module graph_selection {
  type Request = { op: str, arg: str }
  type View = { focus: str, definitions: List[str], readOnly: bool, sameWindow: bool,
    position: str, notices: List[str] }
  type Session = { request: Request, view: View, entry: str, edit: str }
  var session: Session

  pure val barePoints = Set("firstName", "sameLineBody", "nestedLocal", "outside", "moduleHeader",
    "variant", "emptyFile", "destructuringFile")
  pure val namedPoints = Set("firstHeader", "secondHeader", "betweenModules", "wrongModule",
    "soleModule", "filenameFallback", "cursorBeatsFilename", "secondHeaderMac")
  pure val allDefinitions = List("First:same", "First:other", "First:after", "Second:same")
  pure val updatedDefinitions = List("First:same", "First:other", "First:after", "First:added", "Second:same")
  pure val destructuringDefinitions = List("Pattern:Destructuring", "Pattern:total")

  pure def fileDefinitions(point: str, edit: str): List[str] =
    if (point == "destructuringFile") destructuringDefinitions
    else if (edit == "saved") updatedDefinitions else allDefinitions

  pure def source(position: str, notices: List[str]): View = {
    focus: "source", definitions: List(), readOnly: false,
    sameWindow: true, position: position, notices: notices,
  }
  pure def graph(definitions: List[str]): View = {
    focus: "graph", definitions: definitions, readOnly: true,
    sameWindow: true, position: "top", notices: List(),
  }

  pure def bareAt(point: str, edit: str): View =
    if (point == "emptyFile") source("entry", List("noDefinitions"))
    else if (edit == "dirty") source("entry", List("unsaved"))
    else graph(fileDefinitions(point, edit))

  pure def namedAt(point: str): View =
    if (point == "firstHeader") graph(List("First:other", "First:same"))
    else if (Set("secondHeader", "cursorBeatsFilename", "secondHeaderMac").contains(point))
      graph(List("Second:same"))
    else if (point == "filenameFallback") graph(List("First:same"))
    else if (point == "soleModule") graph(List("Only:decide"))
    else if (point == "wrongModule") source("entry", List("unknownName"))
    else source("entry", List("noModule"))

  pure val toggleRequest = { op: "view", arg: "" }
  pure val namedInGraph = { op: "named", arg: "" }
  pure val moveRequest = { op: "moveGraph", arg: "" }
  pure val editRequest = { op: "editSource", arg: "" }
  pure val saveRequest = { op: "saveSource", arg: "" }
  pure val requests = barePoints.map(arg => { op: "view", arg: arg })
    .union(namedPoints.map(arg => { op: "named", arg: arg }))
    .union(Set(toggleRequest, namedInGraph, moveRequest, editRequest, saveRequest))

  action init = session' = { request: { op: "init", arg: "" }, view: source("start", List()),
    entry: "", edit: "clean" }

  val inGraph = session.view.focus == "graph"
  action perform(request: Request): bool = any {
    all {
      not(inGraph), request.op == "view", barePoints.contains(request.arg),
      session.entry == "" or (request.arg == session.entry and request.arg != "emptyFile"),
      session' = { ...session, request: request, entry: request.arg, view: bareAt(request.arg, session.edit) },
    },
    all {
      not(inGraph), session.entry == "", request.op == "named", namedPoints.contains(request.arg),
      session' = { ...session, request: request, entry: request.arg, view: namedAt(request.arg) },
    },
    all {
      inGraph, request == toggleRequest,
      session' = { ...session, request: request, view: source("entry", List()) },
    },
    all {
      inGraph, request == namedInGraph,
      session' = { ...session, request: request, view: { ...session.view, notices: List("namesNeedSource") } },
    },
    all {
      inGraph, request == moveRequest,
      session' = { ...session, request: request, view: { ...session.view, position: "moved", notices: List() } },
    },
    all {
      inGraph, session.entry == "outside", session.edit == "clean", request == editRequest,
      session' = { ...session, request: request, edit: "dirty", view: { ...session.view, notices: List() } },
    },
    all {
      not(inGraph), session.edit == "dirty", request == saveRequest,
      session' = { ...session, request: request, edit: "saved", view: source("entry", List()) },
    },
  }

  action step = any { { nondet request = requests.oneOf(); perform(request) }, session' = session }

  def observationMatches(observed: View): bool = session.view == observed

  val singleWindow = session.view.sameWindow
  val graphIsReadOnly = inGraph == session.view.readOnly
  val bareViewShowsWholeFile = (session.request.op == "view" and session.request.arg != "" and
    session.entry != "emptyFile" and session.edit != "dirty") implies all {
    inGraph, session.view.position == "top", session.view.notices == List(),
    session.view.definitions == fileDefinitions(session.entry, session.edit),
  }
  val toggleRestoresEditableSource = (session.request == toggleRequest) implies
    session.view == source("entry", List())
  val rejectionStaysPut = session.view.notices.length() > 0 implies all {
    session.view.notices.length() == 1,
    if (session.request == namedInGraph) inGraph
    else not(inGraph) and session.view.position == "entry",
  }

  run definitionNameTest = init.then(perform({ op: "view", arg: "firstName" })).expect(bareViewShowsWholeFile)
  run sameLineAfterUnicodeTest = init.then(perform({ op: "view", arg: "sameLineBody" })).expect(bareViewShowsWholeFile)
    .then(perform(moveRequest)).then(perform(toggleRequest)).expect(toggleRestoresEditableSource)
  run nestedLocalTest = init.then(perform({ op: "view", arg: "nestedLocal" })).expect(bareViewShowsWholeFile)
  run moduleHeaderTest = init.then(perform({ op: "view", arg: "moduleHeader" })).expect(bareViewShowsWholeFile)
  run outsideDefinitionTest = init.then(perform({ op: "view", arg: "outside" })).expect(bareViewShowsWholeFile)
  run variantTest = init.then(perform({ op: "view", arg: "variant" })).expect(bareViewShowsWholeFile)
  run declarationOnlyFileTest = init.then(perform({ op: "view", arg: "emptyFile" }))
    .expect(session.view == source("entry", List("noDefinitions")))
  run destructuringAsSourceTest = init.then(perform({ op: "view", arg: "destructuringFile" }))
    .expect(session.view == graph(destructuringDefinitions))
  run dirtySourceToggleAndRebuildTest = init.then(perform({ op: "view", arg: "outside" })).expect(bareViewShowsWholeFile)
    .then(perform(editRequest)).expect(session.view == graph(allDefinitions))
    .then(perform(toggleRequest)).expect(toggleRestoresEditableSource)
    .then(perform({ op: "view", arg: "outside" })).expect(session.view == source("entry", List("unsaved")))
    .then(perform(saveRequest)).then(perform({ op: "view", arg: "outside" }))
    .expect(session.view == graph(updatedDefinitions))
  run namedDefinitionsInOrderTest = init.then(perform({ op: "named", arg: "firstHeader" }))
    .expect(session.view == graph(List("First:other", "First:same")))
    .then(perform(moveRequest)).then(perform(namedInGraph))
    .expect(session.view == { ...graph(List("First:other", "First:same")),
      position: "moved", notices: List("namesNeedSource") })
    .then(perform(toggleRequest)).expect(toggleRestoresEditableSource)
  run namedDefinitionInSecondModuleTest = init.then(perform({ op: "named", arg: "secondHeader" }))
    .expect(session.view == graph(List("Second:same")))
  run ambiguousNamedModuleTest = init.then(perform({ op: "named", arg: "betweenModules" }))
    .expect(session.view == source("entry", List("noModule")))
  run nameDoesNotCrossModulesTest = init.then(perform({ op: "named", arg: "wrongModule" }))
    .expect(session.view == source("entry", List("unknownName")))
  run soleModuleFallbackTest = init.then(perform({ op: "named", arg: "soleModule" }))
    .expect(session.view == graph(List("Only:decide")))
  run filenameFallbackTest = init.then(perform({ op: "named", arg: "filenameFallback" }))
    .expect(session.view == graph(List("First:same")))
  run cursorModuleBeatsFilenameTest = init.then(perform({ op: "named", arg: "cursorBeatsFilename" }))
    .expect(session.view == graph(List("Second:same")))
  run namedDefinitionInMacFileTest = init.then(perform({ op: "named", arg: "secondHeaderMac" }))
    .expect(session.view == graph(List("Second:same")))
}
