import
  std/[json, strutils],
  retro/[bluetooth]

proc main() =
  ## Exercise the public JSON contract and strict command address validation.
  doAssert validateAddress("01:23:45:67:89:AB")
  doAssert validateAddress("aa:bb:cc:dd:ee:ff")
  for address in ["", "01:23:45:67:89", "01-23-45-67-89-AB",
      "01:23:45:67:89:AG", "01:23:45:67:89:AB\n", " 01:23:45:67:89:AB"]:
    doAssert not validateAddress(address)
  let state = BtState(request: 23, available: true, powered: true, busy: true,
    prompt: BtPrompt(kind: ConfirmPrompt, address: "01:23:45:67:89:AB", passkey: 42),
    devices: @[BtDevice(address: "01:23:45:67:89:AB", name: "Controller",
      batteryPercent: -1, paired: true)])
  doAssert stateFromJson(state.stateJson()) == state
  doAssert parseJson(state.stateJson())["prompt"]["kind"].getStr() == "ConfirmPrompt"
  let command = BtCommand(request: 24, action: "reply", value: "test-private-pin")
  doAssert commandFromJson(command.commandJson()) == command
  doAssert commandFromJson("{\"action\":\"status\"}").action == "status"
  doAssert commandFromJson("{\"action\":\"status\"}").request == 0
  doAssert "test-private-pin" notin state.stateJson()
  try:
    discard commandFromJson("test-private-pin invalid JSON")
    doAssert false
  except ValueError as error:
    doAssert error.msg == "Invalid Bluetooth command"
    doAssert "test-private-pin" notin error.msg

when isMainModule:
  main()
