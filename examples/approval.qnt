module approval {
  type State = { pending: bool, owner: str }
  pure val initial: State = { pending: false, owner: "" }

  pure def mayApprove(state: State, reviewer: str): bool =
    state.pending and state.owner != reviewer

  pure def review(state: State, reviewer: str): (str, State) = {
    val allowed = mayApprove(state, reviewer)
    if (allowed) {
      val label = "approved"
      (label, { ...state, pending: false })
    } else {
      val label = "denied"
      (label, state)
    }
  }
}
