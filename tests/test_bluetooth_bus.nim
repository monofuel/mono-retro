import
  std/[json, monotimes, os, osproc, streams, strtabs, strutils, tempfiles, times],
  bluetoothcli,
  retro/[bluetooth, bluezbus]

type
  FakeBluez = ref object
    connection: ptr BusConnection
    pairCall, connectCall: ptr BusMessage
    promptCall: ptr BusPending
    agentDestination, promptMember, captured, failure: string
    powered, discovering, paired, trusted, connected, visible, pcmAvailable: bool
    autoFinish, holdConnect, rejectConnect, modernPcms, adapterPresent: bool
    mutations: seq[string]
    snapshots, stops, cancels, trusts, registrations, unregistrations: int
    defaultRequested: bool

const
  Address = "01:23:45:67:89:AB"
  DevicePath = "/org/bluez/hci0/dev_01_23_45_67_89_AB"
  TestLimits = BtLimits(refreshMs: 15, requestMs: 200, operationMs: 200,
    pairMs: 1000, promptMs: 200, scanMs: 70)

proc snapshot(fake: FakeBluez): JsonNode =
  ## Build genuine typed ObjectManager fixtures rather than Bluetooth CLI text.
  result = newJObject()
  if not fake.adapterPresent: return
  result["/org/bluez/hci0"] = %*{AdapterInterface: {
    "Powered": variant("b", %fake.powered), "Discovering": variant("b", %fake.discovering)}}
  if fake.visible:
    result[DevicePath] = %*{DeviceInterface: {
      "Adapter": variant("o", %"/org/bluez/hci0"), "Address": variant("s", %Address),
      "Alias": variant("s", %"Test controller"), "Icon": variant("s", %"input-gaming"),
      "Paired": variant("b", %fake.paired), "Trusted": variant("b", %fake.trusted),
      "Connected": variant("b", %fake.connected), "ServicesResolved": variant("b", %true),
      "UUIDs": variant("as", %["00001124-0000-1000-8000-00805f9b34fb"])},
      "org.bluez.Battery1": {"Percentage": variant("y", %67)}}

proc pcmSnapshot(fake: FakeBluez): JsonNode =
  ## Describe an available SBC playback transport without claiming it is playing.
  result = newJObject()
  if fake.pcmAvailable:
    let properties = %*{"Device": variant("o", %DevicePath),
      "Transport": variant("s", %"A2DP-source"), "Mode": variant("s", %"sink"),
      "Codec": variant("s", %"SBC"), "Channels": variant("y", %2),
      "Sampling": variant("u", %48000)}
    if fake.modernPcms:
      result["/org/bluealsa/test"] = %*{"org.bluealsa.PCM1": properties}
    else: result["/org/bluealsa/test"] = properties

proc finishPair(fake: FakeBluez, accepted: bool) =
  ## Complete the held Pair call only after the fake agent exchange finishes.
  if fake.pairCall == nil: return
  if accepted:
    fake.paired = true
    sendReply(fake.connection, fake.pairCall)
  else: sendError(fake.connection, fake.pairCall, "org.bluez.Error.AuthenticationRejected")
  messageUnref(fake.pairCall)
  fake.pairCall = nil

proc ask(fake: FakeBluez, member: string, path = DevicePath) =
  ## Send a real directed Agent1 call through the isolated private bus.
  let message = messageNewCall(fake.agentDestination.cstring, AgentPath,
    AgentInterface, member.cstring)
  defer: messageUnref(message)
  var args = @[busArg("o", %path)]
  if member in ["RequestConfirmation", "DisplayPasskey"]: args.add busArg("u", %42)
  if member == "DisplayPasskey": args.add busArg("q", %2)
  if member == "DisplayPinCode": args.add busArg("s", %"001234")
  if member in ["Cancel", "Release"]: args.setLen(0)
  appendArgs(message, args)
  doAssert sendWithReply(fake.connection, message, addr fake.promptCall, 1000) != 0

proc fakeFilter(connection: ptr BusConnection, message: ptr BusMessage,
    data: pointer): BusResult {.cdecl.} =
  ## Implement the documented BlueZ methods, keeping Pair and Connect pending.
  if messageType(message) != 1: return BusNotHandled
  let
    fake = cast[FakeBluez](data)
    member = $messageMember(message)
    path = $messagePath(message)
  try:
    let args = messageArgs(message)
    case member
    of "GetManagedObjects":
      inc fake.snapshots
      if path == "/org/bluealsa":
        sendReply(connection, message, [busArg("a{oa{sa{sv}}}", fake.pcmSnapshot())])
      else: sendReply(connection, message, [busArg("a{oa{sa{sv}}}", fake.snapshot())])
    of "GetPCMs":
      if fake.modernPcms:
        sendError(connection, message, "org.freedesktop.DBus.Error.UnknownMethod")
      else: sendReply(connection, message, [busArg("a{oa{sv}}", fake.pcmSnapshot())])
    of "RegisterAgent":
      doAssert args[0].getStr() == AgentPath and args[1].getStr() == "KeyboardDisplay"
      inc fake.registrations
      fake.agentDestination = $messageSender(message)
      sendReply(connection, message)
    of "UnregisterAgent":
      inc fake.unregistrations
      sendReply(connection, message)
    of "RequestDefaultAgent":
      fake.defaultRequested = true
      sendError(connection, message)
    of "StartDiscovery":
      fake.discovering = true
      fake.mutations.add member
      sendReply(connection, message)
    of "StopDiscovery":
      inc fake.stops
      fake.discovering = false
      sendReply(connection, message)
    of "Set":
      fake.mutations.add member
      if args[0].getStr() == DeviceInterface and args[1].getStr() == "Trusted":
        doAssert fake.paired
        inc fake.trusts
        fake.trusted = args[2].getBool()
      elif args[0].getStr() == AdapterInterface and args[1].getStr() == "Powered":
        fake.powered = args[2].getBool()
      else: doAssert false
      sendReply(connection, message)
    of "Pair":
      doAssert fake.pairCall == nil
      fake.mutations.add member
      fake.pairCall = messageRef(message)
      fake.ask(fake.promptMember)
    of "CancelPairing":
      inc fake.cancels
      fake.finishPair(false)
      sendReply(connection, message)
    of "Connect":
      fake.mutations.add member
      if fake.rejectConnect: sendError(connection, message, "org.bluez.Error.Failed")
      elif fake.holdConnect: fake.connectCall = messageRef(message)
      else:
        fake.connected = true
        sendReply(connection, message)
    of "Disconnect":
      fake.mutations.add member
      fake.connected = false
      if fake.connectCall != nil:
        sendError(connection, fake.connectCall, "org.bluez.Error.Canceled")
        messageUnref(fake.connectCall)
        fake.connectCall = nil
      sendReply(connection, message)
    of "RemoveDevice":
      doAssert args[0].getStr() == DevicePath
      fake.mutations.add member
      fake.visible = false
      sendReply(connection, message)
    else: sendError(connection, message, "org.freedesktop.DBus.Error.UnknownMethod")
    return BusHandled
  except CatchableError as error:
    fake.failure = error.msg
    sendError(connection, message)
    return BusHandled

proc tick(fake: FakeBluez, session: BtSession) =
  ## Dispatch both real libdbus connections without threads or radio access.
  session.pump()
  discard readWriteDispatch(fake.connection, 0)
  if fake.promptCall != nil and pendingCompleted(fake.promptCall) != 0:
    let reply = pendingStealReply(fake.promptCall)
    pendingUnref(fake.promptCall)
    fake.promptCall = nil
    doAssert reply != nil
    let accepted = messageType(reply) == 2
    if accepted:
      let args = messageArgs(reply)
      if args.len > 0: fake.captured = $args[0]
    messageUnref(reply)
    if fake.autoFinish: fake.finishPair(accepted)
  session.pump()
  doAssert fake.failure.len == 0
  sleep(1)

template awaitState(condition: untyped) =
  block:
    let deadline = getMonoTime() + initDuration(seconds = 3)
    while not (condition) and getMonoTime() < deadline:
      fake.tick(session)
    doAssert condition

proc main() =
  ## Exercise Agent1, operations and timeouts against a fresh private daemon only.
  let
    daemon = startProcess(findExe("dbus-daemon"), args = ["--session", "--nofork", "--print-address=1"],
      options = {poUsePath})
    address = daemon.outputStream.readLine()
    fake = FakeBluez(connection: openBus(address), powered: true, visible: true, adapterPresent: true,
      promptMember: "RequestConfirmation", autoFinish: true)
    inputRoot = createTempDir("mono-retro-bt-input-", "")
  doAssert address.startsWith("unix:")
  doAssert busRequestName(fake.connection, BluezService, 4, nil) == 1
  doAssert busRequestName(fake.connection, "org.bluealsa", 4, nil) == 1
  doAssert addFilter(fake.connection, fakeFilter, cast[pointer](fake), nil) != 0
  var session = openBtSession(address, TestLimits, inputRoot)
  defer:
    session.close()
    if fake.pairCall != nil: messageUnref(fake.pairCall)
    if fake.connectCall != nil: messageUnref(fake.connectCall)
    if fake.promptCall != nil:
      pendingCancel(fake.promptCall)
      pendingUnref(fake.promptCall)
    connectionClose(fake.connection)
    connectionUnref(fake.connection)
    daemon.terminate()
    discard daemon.waitForExit()
    daemon.close()
    removeDir(inputRoot)
  awaitState(session.state.available and session.state.devices.len == 1)
  doAssert fake.mutations.len == 0
  doAssert session.state.devices[0].batteryPercent == 67
  doAssert not session.state.devices[0].audioReady
  doAssert not session.state.devices[0].gamepadReady
  fake.adapterPresent = false
  awaitState(not session.state.available)
  doAssert session.state.error == "No Bluetooth adapter is available"
  fake.adapterPresent = true
  awaitState(session.state.available)
  doAssert session.state.error == ""
  session.submit(BtCommand(action: "scan", enabled: true))
  awaitState(fake.discovering)
  awaitState(fake.stops == 1 and not session.state.busy)
  session.submit(BtCommand(action: "power", enabled: false))
  awaitState(not session.state.busy and not session.state.powered)
  session.submit(BtCommand(action: "power", enabled: true))
  awaitState(not session.state.busy and session.state.powered)
  session.submit(BtCommand(action: "pair", address: Address))
  awaitState(session.state.prompt.kind == ConfirmPrompt)
  doAssert session.state.busy and session.state.prompt.passkey == 42
  let beforeSnapshots = fake.snapshots
  awaitState(fake.snapshots > beforeSnapshots)
  doAssert session.state.busy and fake.trusts == 0
  session.submit(BtCommand(action: "reply", value: "yes"))
  awaitState(not session.state.busy and fake.trusts == 1)
  doAssert fake.connected
  doAssert "Connect" in fake.mutations
  doAssert not fake.defaultRequested
  awaitState(session.state.devices[0].trusted)
  fake.promptMember = "RequestPinCode"
  session.submit(BtCommand(action: "pair", address: Address))
  awaitState(session.state.prompt.kind == PinPrompt)
  let
    attacker = openBus(address)
    rogue = messageNewCall(busUniqueName(session.connection), AgentPath,
      AgentInterface, "RequestAuthorization")
  appendArgs(rogue, [busArg("o", %DevicePath)])
  var roguePending: ptr BusPending
  doAssert sendWithReply(attacker, rogue, addr roguePending, 1000) != 0
  messageUnref(rogue)
  let rogueDeadline = getMonoTime() + initDuration(seconds = 1)
  while pendingCompleted(roguePending) == 0 and getMonoTime() < rogueDeadline:
    fake.tick(session)
    discard readWriteDispatch(attacker, 0)
  doAssert pendingCompleted(roguePending) != 0
  let rogueReply = pendingStealReply(roguePending)
  doAssert messageType(rogueReply) == 3
  messageUnref(rogueReply)
  pendingUnref(roguePending)
  connectionClose(attacker)
  connectionUnref(attacker)
  doAssert session.state.prompt.kind == PinPrompt
  session.submit(BtCommand(action: "reply", value: "private-test-pin"))
  awaitState(not session.state.busy and fake.trusts == 2)
  doAssert fake.captured == "\"private-test-pin\""
  doAssert "private-test-pin" notin session.state.stateJson()
  fake.promptMember = "RequestPasskey"
  session.submit(BtCommand(action: "pair", address: Address))
  awaitState(session.state.prompt.kind == PasskeyPrompt)
  try:
    session.submit(BtCommand(action: "reply", value: "1234567"))
    doAssert false
  except ValueError: discard
  doAssert session.state.prompt.kind == PasskeyPrompt
  session.submit(BtCommand(action: "reply", value: "000042"))
  awaitState(not session.state.busy and fake.trusts == 3)
  doAssert fake.captured == "42"
  fake.promptMember = "RequestConfirmation"
  session.submit(BtCommand(action: "pair", address: Address))
  awaitState(session.state.prompt.kind == ConfirmPrompt)
  session.submit(BtCommand(action: "reply", value: "no"))
  awaitState(not session.state.busy)
  doAssert fake.trusts == 3 and "AuthenticationRejected" in session.state.error
  fake.autoFinish = false
  fake.promptMember = "DisplayPasskey"
  session.submit(BtCommand(action: "pair", address: Address))
  awaitState(session.state.prompt.kind == DisplayPrompt)
  doAssert session.state.prompt.passkey == 42 and "2/6" in session.state.prompt.text
  awaitState(fake.promptCall == nil)
  session.submit(BtCommand(action: "cancel"))
  awaitState(fake.cancels >= 1 and fake.pairCall == nil)
  doAssert session.state.prompt.kind == NoPrompt and not session.state.busy
  fake.promptMember = "DisplayPinCode"
  session.submit(BtCommand(action: "pair", address: Address))
  awaitState(session.state.prompt.kind == DisplayPrompt)
  doAssert session.state.prompt.code == "001234"
  awaitState(fake.promptCall == nil)
  session.submit(BtCommand(action: "cancel"))
  awaitState(fake.pairCall == nil)
  fake.promptMember = "RequestPinCode"
  session.submit(BtCommand(action: "pair", address: Address))
  awaitState(session.state.prompt.kind == PinPrompt)
  awaitState(not session.state.busy and fake.pairCall == nil)
  doAssert session.state.error == "Bluetooth pairing prompt timed out"
  doAssert fake.trusts == 3
  fake.holdConnect = true
  session.submit(BtCommand(action: "connect", address: Address))
  awaitState(fake.connectCall != nil)
  let connectSnapshots = fake.snapshots
  awaitState(fake.snapshots > connectSnapshots)
  session.submit(BtCommand(action: "cancel"))
  awaitState(fake.connectCall == nil)
  doAssert not session.state.busy
  session.submit(BtCommand(action: "connect", address: Address))
  awaitState(fake.connectCall != nil)
  awaitState(not session.state.busy and fake.connectCall == nil)
  doAssert "Timeout" in session.state.error or "NoReply" in session.state.error
  fake.holdConnect = false
  session.submit(BtCommand(action: "connect", address: Address))
  awaitState(not session.state.busy and session.state.devices[0].connected)
  doAssert not session.state.devices[0].audioReady
  fake.pcmAvailable = true
  awaitState(session.state.devices[0].audioReady)
  fake.modernPcms = true
  fake.pcmAvailable = false
  awaitState(not session.state.devices[0].audioReady)
  fake.pcmAvailable = true
  awaitState(session.state.devices[0].audioReady)
  doAssert not session.state.devices[0].gamepadReady
  let eventDevice = inputRoot / "event0/device"
  createDir(eventDevice / "capabilities")
  writeFile(eventDevice / "uniq", Address & "\n")
  writeFile(eventDevice / "uevent", "PRODUCT=5/1234/5678/1\n")
  writeFile(eventDevice / "capabilities/key", "1000000000000 0 0 0 0\n")
  awaitState(session.state.devices[0].gamepadReady)
  session.submit(BtCommand(action: "disconnect", address: Address))
  awaitState(not session.state.busy and not session.state.devices[0].connected)
  doAssert not session.state.devices[0].audioReady and not session.state.devices[0].gamepadReady
  session.submit(BtCommand(action: "forget", address: Address))
  awaitState(not session.state.busy and session.state.devices.len == 0)
  doAssert fake.registrations == 1
  session.close()
  fake.visible = true
  fake.paired = false
  fake.trusted = false
  fake.autoFinish = true
  fake.promptMember = "RequestPinCode"
  let
    statePath = inputRoot / "worker.json"
    environment = newStringTable(modeCaseSensitive)
    previousUnregistrations = fake.unregistrations
  for key, value in envPairs(): environment[key] = value
  environment["DBUS_SYSTEM_BUS_ADDRESS"] = address
  environment["MONO_RETRO_TEST_BT_WORKER"] = "1"
  let worker = startProcess(getAppFilename(), args = ["--state:" & statePath],
    env = environment, options = {})
  defer:
    if worker.running():
      worker.terminate()
      discard worker.waitForExit()
    worker.close()
  proc workerState(): BtState =
    ## Read only complete atomically published snapshots from the child worker.
    if fileExists(statePath): result = stateFromJson(readFile(statePath))
  awaitState(workerState().available)
  doAssert workerState().request == 0
  doAssert getFilePermissions(statePath) == {fpUserRead, fpUserWrite}
  worker.inputStream.writeLine(BtCommand(request: 31, action: "status").commandJson())
  worker.inputStream.flush()
  awaitState(workerState().request == 31)
  let firstStatus = workerState()
  worker.inputStream.writeLine(BtCommand(request: 32, action: "status").commandJson())
  worker.inputStream.flush()
  awaitState(workerState().request == 32)
  var secondStatus = workerState()
  secondStatus.request = firstStatus.request
  doAssert firstStatus == secondStatus
  fake.rejectConnect = true
  worker.inputStream.writeLine(BtCommand(request: 33, action: "connect", address: Address).commandJson())
  worker.inputStream.flush()
  awaitState(workerState().request == 33 and not workerState().busy and workerState().error.len > 0)
  fake.rejectConnect = false
  worker.inputStream.writeLine(BtCommand(request: 34, action: "connect", address: Address).commandJson())
  worker.inputStream.flush()
  awaitState(workerState().request == 34 and not workerState().busy and workerState().error.len == 0 and
    workerState().devices.len > 0 and workerState().devices[0].connected)
  worker.inputStream.writeLine(BtCommand(action: "pair", address: Address).commandJson())
  worker.inputStream.flush()
  awaitState(workerState().prompt.kind == PinPrompt)
  worker.inputStream.writeLine(BtCommand(action: "reply", value: "cli-private-pin").commandJson())
  worker.inputStream.flush()
  awaitState(workerState().devices.len > 0 and workerState().devices[0].trusted)
  doAssert "cli-private-pin" notin readFile(statePath)
  worker.inputStream.writeLine(BtCommand(action: "scan", enabled: true).commandJson())
  worker.inputStream.flush()
  awaitState(fake.discovering)
  worker.inputStream.close()
  awaitState(not worker.running())
  doAssert worker.waitForExit() == 0
  doAssert not fake.discovering
  doAssert fake.unregistrations > previousUnregistrations
  doAssert worker.outputStream.readAll() == ""
  doAssert worker.errorStream.readAll() == ""
  doAssert workerState().prompt.kind == NoPrompt
  doAssert getFilePermissions(statePath) == {fpUserRead, fpUserWrite}
  doAssert not fake.defaultRequested
  let
    mutationCount = fake.mutations.len
    inspector = startProcess(getAppFilename(), args = ["--once:status"],
      env = environment, options = {})
  awaitState(not inspector.running())
  doAssert inspector.waitForExit() == 0
  let inspected = stateFromJson(inspector.outputStream.readAll())
  doAssert inspected.available and inspected.prompt.kind == NoPrompt
  doAssert inspected.request == 0
  doAssert inspector.errorStream.readAll() == ""
  inspector.close()
  doAssert fake.mutations.len == mutationCount
  let
    cancelCount = fake.cancels
    terminatedStatePath = inputRoot / "terminated-worker.json"
    terminatedWorker = startProcess(getAppFilename(), args = ["--state:" & terminatedStatePath],
      env = environment, options = {})
  defer:
    if terminatedWorker.running():
      terminatedWorker.terminate()
      discard terminatedWorker.waitForExit()
    terminatedWorker.close()
  proc terminatedState(): BtState =
    ## Observe prompt cleanup after SIGTERM without touching the host's bus.
    if fileExists(terminatedStatePath): result = stateFromJson(readFile(terminatedStatePath))
  awaitState(terminatedState().available)
  terminatedWorker.inputStream.writeLine(BtCommand(action: "pair", address: Address).commandJson())
  terminatedWorker.inputStream.flush()
  awaitState(terminatedState().prompt.kind == PinPrompt)
  terminatedWorker.terminate()
  awaitState(not terminatedWorker.running())
  doAssert terminatedWorker.waitForExit() == 0
  doAssert fake.cancels > cancelCount and fake.pairCall == nil
  doAssert terminatedState().prompt.kind == NoPrompt
  doAssert terminatedWorker.outputStream.readAll() == ""
  doAssert terminatedWorker.errorStream.readAll() == ""

when isMainModule:
  if getEnv("MONO_RETRO_TEST_BT_WORKER") == "1": runBluetooth()
  else: main()
