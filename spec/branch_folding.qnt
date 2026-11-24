// The graph of decide in tests/fixtures/branch_folding.qnt has an inner
// decision in the outer Yes branch, and a one-line outer No branch.
module branch_folding {
  type Request = { op: str, arg: str }
  type View = { focus: str, folded: List[str] }
  type Session = { request: Request, closed: Set[str], view: View }
  var session: Session

  pure val initRequest = { op: "init", arg: "" }
  pure val showRequest = { op: "showGraph", arg: "decide" }
  pure val deepRequest = { op: "showGraph", arg: "deep" }
  pure val branches = Set("outerYes", "innerYes", "innerNo", "outerNo", "depth20Yes")
  pure val inner = Set("innerYes", "innerNo")
  pure val foldOps = Set("close", "open", "toggle")

  pure def indicated(closed: Set[str], branch: str): List[str] =
    if (closed.contains(branch)) List(branch) else List()

  // Only the outermost closed fold is displayed. Each entry describes an
  // entire branch collapsed to its own heading, in screen order.
  pure def graphView(closed: Set[str]): View = {
    focus: "graph",
    folded: (if (closed.contains("outerYes")) List("outerYes")
      else indicated(closed, "innerYes").concat(indicated(closed, "innerNo")))
      .concat(indicated(closed, "outerNo")),
  }

  action init = session' = {
    request: initRequest, closed: Set(), view: { focus: "source", folded: List() },
  }

  action showGraph(request: Request): bool = all {
    session.view.focus == "source",
    Set(showRequest, deepRequest).contains(request),
    session' = { request: request, closed: Set(), view: {
      focus: if (request == deepRequest) "deepGraph" else "graph", folded: List(),
    } },
  }

  action changeFold(request: Request): bool = all {
    session.view.focus != "source",
    foldOps.contains(request.op),
    branches.contains(request.arg),
    (session.view.focus == "deepGraph") == (request.arg == "depth20Yes"),
    inner.contains(request.arg) implies not(session.closed.contains("outerYes")),
    // A native zc on a closed child may close its parent. This slice only
    // issues zc on an open branch and zo on a closed branch.
    (request.op == "close") implies not(session.closed.contains(request.arg)),
    (request.op == "open") implies session.closed.contains(request.arg),
    val nextClosed = if (request.op == "close" or
      (request.op == "toggle" and not(session.closed.contains(request.arg))))
      session.closed.union(Set(request.arg)) else session.closed.exclude(Set(request.arg))
    val view = if (session.view.focus == "deepGraph")
      { ...session.view, folded: indicated(nextClosed, "depth20Yes") } else graphView(nextClosed)
    session' = { request: request, closed: nextClosed, view: view },
  }

  action perform(request: Request): bool = any {
    showGraph(request),
    changeFold(request),
  }

  action step = any {
    perform(showRequest),
    perform(deepRequest),
    {
      nondet op = foldOps.oneOf()
      nondet branch = branches.oneOf()
      perform({ op: op, arg: branch })
    },
  }

  def observationMatches(observed: View): bool = session.view == observed

  val initiallyExpanded = (session.request.op == "showGraph") implies session.view.folded == List()
  val displayed = session.view.folded.foldl(Set(), (seen, branch) => seen.union(Set(branch)))
  val onlyVisibleBranchesFolded = all {
    displayed.subseteq(branches),
    displayed.size() == session.view.folded.length(),
    displayed.contains("outerYes") implies displayed.intersect(inner) == Set(),
  }
  val nativeFoldClosesOrOpens = all {
    (session.request.op == "close") implies displayed.contains(session.request.arg),
    (session.request.op == "open") implies not(displayed.contains(session.request.arg)),
  }

  run siblingFoldsTest = init
    .then(perform(showRequest))
    .expect(session.view.folded == List())
    .then(perform({ op: "close", arg: "outerYes" }))
    .expect(session.view.folded == List("outerYes"))
    .then(perform({ op: "toggle", arg: "outerNo" }))
    .expect(session.view.folded == List("outerYes", "outerNo"))
    .then(perform({ op: "open", arg: "outerYes" }))
    .expect(session.view.folded == List("outerNo"))
    .then(perform({ op: "toggle", arg: "outerNo" }))
    .expect(session.view.folded == List())

  run nestedFoldsTest = init
    .then(perform(showRequest))
    .then(perform({ op: "close", arg: "innerNo" }))
    .expect(session.view.folded == List("innerNo"))
    .then(perform({ op: "close", arg: "innerYes" }))
    .expect(session.view.folded == List("innerYes", "innerNo"))
    .then(perform({ op: "close", arg: "outerYes" }))
    .expect(session.view.folded == List("outerYes"))
    .then(perform({ op: "open", arg: "outerYes" }))
    .expect(session.view.folded == List("innerYes", "innerNo"))
    .then(perform({ op: "toggle", arg: "innerYes" }))
    .expect(session.view.folded == List("innerNo"))

  // The first 20 nesting levels can fold independently in Neovim. The last
  // supported fold must still contain its entire deeper subtree.
  run deepFoldContainsBodyTest = init
    .then(perform(deepRequest))
    .expect(session.view.folded == List())
    .then(perform({ op: "close", arg: "depth20Yes" }))
    .expect(session.view.folded == List("depth20Yes"))
    .then(perform({ op: "open", arg: "depth20Yes" }))
    .expect(session.view.folded == List())
}
