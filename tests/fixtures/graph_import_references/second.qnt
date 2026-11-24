module second {
  import policy as other from "./policy"
  pure val again = other::allowed(false)
}
