module policy {
  // The organization-wide rule for standard access.
  pure def allowed(isMember: bool, hasTraining: bool): bool =
    isMember and hasTraining
}
