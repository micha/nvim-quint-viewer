module access_review {
  import policy as org from "./policy"

  // A local exception for admins with a ticket. This is not org::allowed.
  pure def allowed(isAdmin: bool, hasTicket: bool): bool =
    isAdmin and hasTicket

  pure def review(isMember: bool, hasTraining: bool, isAdmin: bool, hasTicket: bool): str = {
    val eligible = org::allowed(isMember, hasTraining)
    if (eligible) {
      if (hasTicket) "approved" else "needs ticket"
    } else {
      if (allowed(isAdmin, hasTicket)) "approved by exception" else "denied"
    }
  }
}
