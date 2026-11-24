// Public selection cases from tests/fixtures/graph_selection.qnt. Points
// name source positions, not parser IDs or the graph rows expected there.
module graph_selection {
  type Request = { op: str, arg: str }
  type View = { focus: str, moduleName: str, definitions: List[str],
    readOnly: bool, sameWindow: bool, cursorKept: bool, notices: List[str] }
  type Session = { request: Request, view: View }
  var session: Session

  pure val cursorPoints = Set("firstName", "sameLineBody", "nestedLocal", "outside", "moduleHeader", "variant")
  pure val namedPoints = Set("firstHeader", "secondHeader", "betweenModules", "wrongModule",
    "soleModule", "filenameFallback", "cursorBeatsFilename", "secondHeaderMac")

  pure def plain(focus: str, notices: List[str]): View = {
    focus: focus, moduleName: "", definitions: List(), readOnly: false,
    sameWindow: true, cursorKept: true, notices: notices,
  }

  pure def graph(moduleName: str, definitions: List[str]): View = {
    focus: "graph", moduleName: moduleName, definitions: definitions, readOnly: true,
    sameWindow: true, cursorKept: false, notices: List(),
  }

  pure def byCursor(point: str): View =
    if (point == "firstName") graph("First", List("same"))
    else if (point == "sameLineBody") graph("First", List("other"))
    else if (point == "nestedLocal") graph("Second", List("same"))
    else plain("source", List("noDefinition"))

  pure def byName(point: str): View =
    if (point == "firstHeader") graph("First", List("other", "same"))
    else if (Set("secondHeader", "cursorBeatsFilename", "secondHeaderMac").contains(point))
      graph("Second", List("same"))
    else if (point == "filenameFallback") graph("First", List("same"))
    else if (point == "soleModule") graph("Only", List("decide"))
    else if (point == "wrongModule") plain("source", List("unknownName"))
    else plain("source", List("noModule"))

  action init = session' = { request: { op: "init", arg: "" }, view: plain("source", List()) }

  action perform(request: Request): bool = all {
    session.request.op == "init",
    any {
      request.op == "cursor" and cursorPoints.contains(request.arg),
      request.op == "named" and namedPoints.contains(request.arg),
    },
    val view = if (request.op == "cursor") byCursor(request.arg) else byName(request.arg)
    session' = { request: request, view: view },
  }

  action step = any {
    { nondet arg = cursorPoints.oneOf(); perform({ op: "cursor", arg: arg }) },
    { nondet arg = namedPoints.oneOf(); perform({ op: "named", arg: arg }) },
  }

  def observationMatches(observed: View): bool = session.view == observed

  val graphIsReadOnly = session.view.focus == "graph" implies all {
    session.view.readOnly, session.view.sameWindow, session.view.definitions.length() > 0,
    session.view.notices == List(),
  }
  val cursorUsesEnclosingDefinition = session.request.op == "cursor" implies all {
    session.request.arg == "sameLineBody" implies session.view.definitions == List("other"),
    session.request.arg == "nestedLocal" implies all {
      session.view.moduleName == "Second", session.view.definitions == List("same"),
    },
  }
  val rejectionKeepsSource = session.view.notices.length() > 0 implies all {
    session.view.focus == "source", session.view.sameWindow, session.view.cursorKept,
    session.view.definitions == List(), session.view.notices.length() == 1,
  }

  run definitionNameTest = init.then(perform({ op: "cursor", arg: "firstName" }))
    .expect(session.view == graph("First", List("same")))
  run sameLineAfterUnicodeTest = init.then(perform({ op: "cursor", arg: "sameLineBody" }))
    .expect(session.view == graph("First", List("other")))
  run nestedLocalUsesOuterTest = init.then(perform({ op: "cursor", arg: "nestedLocal" }))
    .expect(session.view == graph("Second", List("same")))
  run moduleHeaderIsNotDefinitionTest = init.then(perform({ op: "cursor", arg: "moduleHeader" }))
    .expect(session.view == plain("source", List("noDefinition")))
  run outsideDefinitionTest = init.then(perform({ op: "cursor", arg: "outside" }))
    .expect(session.view == plain("source", List("noDefinition")))
  run variantIsNotADefinitionTest = init.then(perform({ op: "cursor", arg: "variant" }))
    .expect(session.view == plain("source", List("noDefinition")))
  run namedDefinitionsInOrderTest = init.then(perform({ op: "named", arg: "firstHeader" }))
    .expect(session.view == graph("First", List("other", "same")))
  run namedDefinitionInSecondModuleTest = init.then(perform({ op: "named", arg: "secondHeader" }))
    .expect(session.view == graph("Second", List("same")))
  run ambiguousNamedModuleTest = init.then(perform({ op: "named", arg: "betweenModules" }))
    .expect(session.view == plain("source", List("noModule")))
  run nameDoesNotCrossModulesTest = init.then(perform({ op: "named", arg: "wrongModule" }))
    .expect(session.view == plain("source", List("unknownName")))
  run soleModuleFallbackTest = init.then(perform({ op: "named", arg: "soleModule" }))
    .expect(session.view == graph("Only", List("decide")))
  run filenameFallbackTest = init.then(perform({ op: "named", arg: "filenameFallback" }))
    .expect(session.view == graph("First", List("same")))
  run cursorModuleBeatsFilenameTest = init.then(perform({ op: "named", arg: "cursorBeatsFilename" }))
    .expect(session.view == graph("Second", List("same")))
  run namedDefinitionInMacFileTest = init.then(perform({ op: "named", arg: "secondHeaderMac" }))
    .expect(session.view == graph("Second", List("same")))
}
