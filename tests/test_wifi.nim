import
  std/[atomics, json, os, osproc, posix, streams, strutils, tempfiles],
  retro/[wifi, wpasocket]

type
  FakeNetwork = object
    id: int
    ssid: string
    disabled, tempDisabled, hasPsk: bool
  Outcome = enum
    Joins, RejectsPassword, NeverJoins, FailsPskCommand, SameAddress, LoopbackAddress,
    SwitchesOnEnable
  FakeWpa = ref object
    networks: seq[FakeNetwork]
    current, selected, nextId, polls: int
    outcome: Outcome
    ipAddress, version: string
    log: seq[string]

const
  Password = "correct horse"
  PasswordKey = "cb3b7b0a636336e9a34420916a5c2c186305a531766654bc5a42f423f271831a"
  ScanReply = "bssid / frequency / signal level / flags / ssid\n" &
    "aa:bb:cc:dd:ee:01\t2412\t-40\t[WPA2-PSK-CCMP][ESS]\tHome\n" &
    "aa:bb:cc:dd:ee:02\t5180\t-70\t[WPA2-PSK-CCMP][ESS]\tHome\n" &
    "aa:bb:cc:dd:ee:03\t2437\t-55\t[WPA2-PSK-CCMP][ESS]\t\\xe2\\x98\\x95 caf\\xc3\\xa9\n" &
    "aa:bb:cc:dd:ee:04\t2437\t-60\t[ESS]\tsay \\\"hi\\\"\\\\\n" &
    "aa:bb:cc:dd:ee:05\t2437\t-61\t[WPA2-EAP-CCMP][ESS]\tOffice\n" &
    "aa:bb:cc:dd:ee:06\t2437\t-62\t[WPA2-SAE-CCMP][ESS]\tModern\n" &
    "aa:bb:cc:dd:ee:07\t2437\t-63\t[WPA2-PSK+SAE-CCMP][ESS]\tMixed\n" &
    "aa:bb:cc:dd:ee:08\t2437\t-64\t[ESS]\t\\x00\\x00\n" &
    "aa:bb:cc:dd:ee:09\t2437\t-65\t[WEP][ESS]\tOld\\tTab\n"

proc newFake(outcome = Joins): FakeWpa =
  ## Start with three saved networks: Home connected, Phone disabled and Cabin
  ## enabled but out of range.
  FakeWpa(outcome: outcome, current: 0, selected: 0, nextId: 3, ipAddress: "192.0.2.10",
    version: "2.12", networks: @[FakeNetwork(id: 0, ssid: "Home", hasPsk: true),
      FakeNetwork(id: 1, ssid: "Phone", hasPsk: true, disabled: true),
      FakeNetwork(id: 2, ssid: "Cabin", hasPsk: true)])

proc find(fake: FakeWpa, id: int): int =
  ## Return the index of a network id, or -1.
  for index, network in fake.networks:
    if network.id == id: return index
  -1

proc handle(fake: FakeWpa, command: string): string =
  ## Model the subset of wpa_supplicant control replies used by the client.
  fake.log.add command
  let parts = command.split(' ', 3)
  case parts[0]
  of "PING": "PONG\n"
  of "GET": (if parts.len > 1 and parts[1] == "version": fake.version & "\n" else: "FAIL\n")
  of "STATUS":
    if fake.selected != fake.current and fake.selected >= 0:
      inc fake.polls
      if fake.outcome in {Joins, SameAddress, LoopbackAddress, SwitchesOnEnable} and fake.polls >= 2:
        fake.current = fake.selected
        fake.ipAddress = case fake.outcome
          of SameAddress: fake.ipAddress
          of LoopbackAddress: "127.0.0.1"
          else: "198.51.100.7"
      elif fake.outcome == RejectsPassword and fake.polls >= 3:
        fake.networks[fake.find(fake.selected)].tempDisabled = true
    if fake.current >= 0 and fake.current == fake.selected:
      let index = fake.find(fake.current)
      "bssid=aa:bb:cc:dd:ee:01\nid=" & $fake.current & "\nssid=" & fake.networks[index].ssid &
        "\nkey_mgmt=WPA2-PSK\nwpa_state=COMPLETED\nip_address=" & fake.ipAddress & "\n"
    else: "wpa_state=" & (if fake.polls == 1: "ASSOCIATING" else: "SCANNING") & "\n"
  of "LIST_NETWORKS":
    var reply = "network id / ssid / bssid / flags\n"
    for network in fake.networks:
      var flags = ""
      if network.id == fake.current and network.id == fake.selected: flags &= "[CURRENT]"
      if network.disabled: flags &= "[DISABLED]"
      if network.tempDisabled: flags &= "[TEMP-DISABLED]"
      reply &= $network.id & "\t" & network.ssid & "\tany\t" & flags & "\n"
    reply
  of "SCAN_RESULTS": ScanReply
  of "SCAN": "OK\n"
  of "ADD_NETWORK":
    fake.networks.add FakeNetwork(id: fake.nextId, disabled: true)
    inc fake.nextId
    $(fake.nextId - 1) & "\n"
  of "SET_NETWORK":
    let index = fake.find(parseInt(parts[1]))
    if index < 0: return "FAIL\n"
    case parts[2]
    of "ssid": fake.networks[index].ssid = hexToSsid(parts[3])
    of "psk":
      if fake.outcome == FailsPskCommand: return "FAIL\n"
      fake.networks[index].hasPsk = true
    else: discard
    "OK\n"
  of "SELECT_NETWORK":
    let index = fake.find(parseInt(parts[1]))
    if index < 0: return "FAIL\n"
    for network in fake.networks.mitems: network.disabled = network.id != parseInt(parts[1])
    fake.selected = parseInt(parts[1])
    fake.polls = 0
    if fake.selected == 0: fake.current = 0
    elif fake.selected != fake.current: fake.current = -1
    "OK\n"
  of "ENABLE_NETWORK", "DISABLE_NETWORK":
    let
      id = parseInt(parts[1])
      index = fake.find(id)
    if index < 0: return "FAIL\n"
    fake.networks[index].disabled = parts[0] == "DISABLE_NETWORK"
    if parts[0] == "ENABLE_NETWORK":
      # A plain enable while disconnected makes the daemon pick a network itself.
      let reconnects = (not command.endsWith(" no-connect") and fake.current < 0) or
        (fake.outcome == SwitchesOnEnable and fake.current >= 3)
      if reconnects:
        fake.selected = id
        fake.current = id
    "OK\n"
  of "REMOVE_NETWORK":
    let index = fake.find(parseInt(parts[1]))
    if index < 0: return "FAIL\n"
    fake.networks.delete(index)
    "OK\n"
  else: "UNKNOWN COMMAND\n"

proc hooks(progress: ptr seq[string], persisted: ptr seq[string], cancelAfter = -1): ConnectHooks =
  ## Use a simulated clock so timeouts run instantly.
  let
    elapsed = new int
    polls = new int
  proc cancelled(): bool =
    ## Report cancellation after a fixed number of checks.
    inc polls[]
    cancelAfter >= 0 and polls[] > cancelAfter
  proc report(message: string) =
    ## Record progress text.
    progress[].add message
  proc wait(milliseconds: int) =
    ## Advance the simulated clock.
    elapsed[] += milliseconds
  proc elapsedMs(): int =
    ## Read the simulated clock.
    elapsed[]
  proc persist(networkBlock: string) =
    ## Record a profile instead of writing it.
    persisted[].add networkBlock
  ConnectHooks(progress: report, cancelled: cancelled, sleep: wait,
    elapsedMs: elapsedMs, persist: persist)

proc transport(fake: FakeWpa): WpaTransport =
  ## Route client commands to the fake daemon.
  result = proc(command: string): string = fake.handle(command)

proc assertSecretAbsent(texts: varargs[string]) =
  ## Fail if the password or its derived key appears anywhere it must not.
  for text in texts: doAssert Password notin text and PasswordKey notin text, text

proc assertEnablesDoNotReconnect(fake: FakeWpa) =
  ## Require every enable to use the non-reconnecting form and no secret reads.
  for command in fake.log:
    doAssert not command.startsWith("GET_NETWORK")
    if command.startsWith("ENABLE_NETWORK"): doAssert command.endsWith(" no-connect"), command

proc assertRestored(fake: FakeWpa) =
  ## Require the original connection and enabled set, without temporary networks.
  doAssert fake.networks.len == 3, $fake.networks.len
  doAssert fake.selected == 0 and fake.current == 0
  doAssert not fake.networks[0].disabled and fake.networks[1].disabled and
    not fake.networks[2].disabled
  fake.assertEnablesDoNotReconnect()

proc testParsing() =
  ## Decode escaped SSIDs, classify security and link saved networks.
  let
    fake = newFake()
    status = parseStatus(fake.handle("STATUS"))
    saved = parseNetworks(fake.handle("LIST_NETWORKS"))
    networks = parseScan(ScanReply, saved, status)
  doAssert status.state == "COMPLETED" and status.ssid == "Home" and status.networkId == 0
  doAssert status.ipAddress == "192.0.2.10"
  doAssert saved.len == 3 and saved[1].flags == "[DISABLED]"
  var names: seq[string]
  for network in networks: names.add network.ssid
  doAssert names == @["Home", "☕ café", "say \"hi\"\\", "Office", "Modern", "Mixed", "Old\tTab"]
  doAssert networks[0].signal == -40 and networks[0].savedId == 0 and networks[0].current
  doAssert networks[0].security == PersonalSecurity
  doAssert hexToSsid(networks[1].ssidHex) == "☕ café"
  doAssert networks[2].security == OpenSecurity and networks[2].savedId == -1
  doAssert networks[3].security == EnterpriseSecurity
  doAssert networks[4].security == Wpa3OnlySecurity
  doAssert networks[5].security == PersonalSecurity
  doAssert networks[6].security == WepSecurity
  doAssert displaySsid(networks[6].ssid) == "Old?Tab"
  doAssert displaySsid("bad\xffbyte") == "bad?byte"
  doAssert printfDecode("\\101\\x41\\\\") == "AA\\"
  for network in networks:
    let decoded = networkFromJson(parseJson($network.toJson()))
    doAssert decoded.ssidHex == network.ssidHex and decoded.security == network.security
  for malformed in 0 .. 2:
    var rejected = false
    try:
      case malformed
      of 0: discard parseStatus("wpa_state=COMPLETED\nid=not-a-number\n")
      of 1: discard parseNetworks("network id / ssid / bssid / flags\ninvalid\tHome\tany\t[CURRENT]\n")
      else: discard parseScan("bssid / frequency / signal level / flags / ssid\n" &
        "aa:bb:cc:dd:ee:ff\t2412\tinvalid\t[ESS]\tHome\n")
    except ValueError: rejected = true
    doAssert rejected

proc testKeys() =
  ## Derive WPA keys with PBKDF2-HMAC-SHA1 and keep raw keys and passphrases out of blocks.
  # IEEE 802.11i annex test vectors.
  doAssert pskHex("password", "IEEE") ==
    "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"
  doAssert pskHex("ThisIsAPassword", "ThisIsASSID") ==
    "0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af"
  # Characters that are awkward in quoted configuration values, checked against Python hashlib.
  doAssert pskHex("pa\"ss # word\\x", "Café \"x\"") ==
    "13705cbbd77871707443a81c9430c18c5aead121ad4eb86842e5a3476a3082dc"
  doAssert pskHex("\"#\\\"quoted\\\\", "Home") ==
    "4de3ad95dffe931b25832b0101bd01c3a564e19fb42a3ab9df745d31702a0eb6"
  doAssert pskHex(Password, "Café") == PasswordKey
  doAssert pskHex('A'.repeat(64), "x") == 'a'.repeat(64)
  validatePassword('~'.repeat(63))
  for bad in ["short", 'x'.repeat(64), 'a'.repeat(65), "tab\there!", "naïve-pass"]:
    var raised = false
    try: discard pskHex(bad, "Home")
    except ValueError as error:
      raised = true
      doAssert bad notin error.msg
    doAssert raised, bad
  let wpaBlock = networkBlock("Café \"x\"", PersonalSecurity, pskHex("pa\"ss # word\\x", "Café \"x\""))
  doAssert "ssid=" & "Café \"x\"".ssidToHex() in wpaBlock and wpaBlock.startsWith("\nnetwork={")
  doAssert "\tpsk=13705cbbd77871707443a81c9430c18c5aead121ad4eb86842e5a3476a3082dc\n" in wpaBlock
  doAssert "word" notin wpaBlock and "\"" notin wpaBlock
  doAssert "key_mgmt=NONE" in networkBlock("Open", OpenSecurity, "")

proc testAddresses() =
  ## Accept only usable IPv4 host addresses.
  for good in ["192.0.2.10", "10.0.0.1", "198.51.100.7", "223.255.255.254"]:
    doAssert good.usableAddress(), good
  for bad in ["", "0.0.0.0", "0.1.2.3", "127.0.0.1", "169.254.3.4", "255.255.255.255",
      "224.0.0.1", "1.2.3", "1.2.3.4.5", "1.2.3.256", "01.2.3.4", "a.b.c.d", "1.2.3.4 ",
      "::1"]:
    doAssert not bad.usableAddress(), bad

proc testNewNetworkSuccess() =
  ## Join a new network, wait for an address, then persist it exactly once.
  let fake = newFake()
  var progress, persisted: seq[string]
  let connected = fake.transport.connect(ConnectRequest(savedId: -1, ssid: "Café",
    security: PersonalSecurity, password: Password, timeoutMs: 30000),
    hooks(addr progress, addr persisted))
  doAssert connected.added and connected.saved and connected.saveError == ""
  doAssert connected.ipAddress == "198.51.100.7" and connected.networkId == 3
  doAssert connected.addressChanged and connected.readiness == ""
  doAssert persisted.len == 1 and "\tpsk=" & PasswordKey & "\n" in persisted[0]
  doAssert Password notin persisted[0]
  doAssert fake.current == 3 and fake.networks.len == 4
  doAssert not fake.networks[0].disabled and not fake.networks[2].disabled,
    "previously enabled networks are enabled again"
  doAssert fake.networks[1].disabled, "previously disabled networks stay disabled"
  doAssert "SET_NETWORK 3 psk " & PasswordKey in fake.log
  doAssert "SET_NETWORK 3 ssid " & "Café".ssidToHex() in fake.log
  doAssert "ENABLE_NETWORK 0 no-connect" in fake.log and "ENABLE_NETWORK 2 no-connect" in fake.log
  doAssert fake.log[^1] == "STATUS", "the connection is confirmed after re-enabling"
  for command in fake.log: doAssert Password notin command
  fake.assertEnablesDoNotReconnect()
  doAssert progress[^1].startsWith("Connected to Café")
  assertSecretAbsent(progress & @[connected.ssid, connected.ipAddress, connected.saveError])

proc testSameAddress() =
  ## A switch that keeps the previous address succeeds but reports unconfirmed readiness.
  let fake = newFake(SameAddress)
  var progress, persisted: seq[string]
  let connected = fake.transport.connect(ConnectRequest(savedId: -1, ssid: "Café",
    security: PersonalSecurity, password: Password, timeoutMs: 30000),
    hooks(addr progress, addr persisted))
  doAssert connected.ipAddress == "192.0.2.10" and not connected.addressChanged
  doAssert "unconfirmed" in connected.readiness and "Internet" notin connected.readiness
  doAssert connected.saved and persisted.len == 1

proc testSavedReuse() =
  ## Reuse saved networks without sending or persisting a password.
  for request in [ConnectRequest(savedId: 1, timeoutMs: 30000),
      ConnectRequest(savedId: -1, ssid: "Phone", security: PersonalSecurity, timeoutMs: 30000)]:
    let fake = newFake()
    var progress, persisted: seq[string]
    let connected = fake.transport.connect(request, hooks(addr progress, addr persisted))
    doAssert not connected.added and connected.reusedProfile and persisted.len == 0
    doAssert connected.networkId == 1 and fake.current == 1
    for command in fake.log:
      doAssert not command.startsWith("ADD_NETWORK") and not command.startsWith("SET_NETWORK")
    doAssert not fake.networks[0].disabled and not fake.networks[2].disabled
    fake.assertEnablesDoNotReconnect()
  # A newly typed password is never silently replaced by the saved one.
  let fake = newFake()
  var progress, persisted: seq[string]
  var raised = false
  try:
    discard fake.transport.connect(ConnectRequest(savedId: -1, ssid: "Phone",
      security: PersonalSecurity, password: Password, timeoutMs: 30000),
      hooks(addr progress, addr persisted))
  except ValueError as error:
    raised = true
    doAssert "saved profile" in error.msg
    assertSecretAbsent(error.msg)
  doAssert raised and fake.log == @["GET version", "LIST_NETWORKS", "STATUS"]

proc expectFailure(fake: FakeWpa, request: ConnectRequest, cancelAfter = -1): string =
  ## Run a failing connection and return its error after checking common guarantees.
  var progress, persisted: seq[string]
  try:
    discard fake.transport.connect(request, hooks(addr progress, addr persisted, cancelAfter))
    doAssert false, "connection should fail"
  except CatchableError as error:
    result = error.msg
    if cancelAfter >= 0: doAssert error of WifiCancelled
  doAssert persisted.len == 0
  doAssert "restore incomplete" notin result, result
  assertSecretAbsent(progress & @[result])
  fake.assertRestored()

proc testFailures() =
  ## Restore the prior connection after rejected passwords, timeouts, cancels and command failures.
  let request = ConnectRequest(savedId: -1, ssid: "Café", security: PersonalSecurity,
    password: Password, timeoutMs: 30000)
  let rejected = newFake(RejectsPassword)
  doAssert "check the password" in rejected.expectFailure(request)
  doAssert "REMOVE_NETWORK 3" in rejected.log and "SELECT_NETWORK 0" in rejected.log
  doAssert "ENABLE_NETWORK 2 no-connect" in rejected.log
  let timeout = newFake(NeverJoins)
  doAssert "Timed out" in timeout.expectFailure(request)
  let cancelled = newFake(NeverJoins)
  doAssert "cancelled" in cancelled.expectFailure(request, cancelAfter = 3)
  let loopback = newFake(LoopbackAddress)
  doAssert "Timed out" in loopback.expectFailure(request)
  let switched = newFake(SwitchesOnEnable)
  doAssert "did not stay connected" in switched.expectFailure(request)
  let commandFailure = newFake(FailsPskCommand)
  let message = commandFailure.expectFailure(request)
  doAssert message == "wpa_supplicant rejected SET_NETWORK psk", message
  let added = commandFailure.log.find("ADD_NETWORK")
  doAssert commandFailure.log[added + 1 .. ^1] == @["SET_NETWORK 3 ssid " & "Café".ssidToHex(),
    "SET_NETWORK 3 key_mgmt WPA-PSK", "SET_NETWORK 3 psk " & PasswordKey, "REMOVE_NETWORK 3",
    "LIST_NETWORKS"], "staging failures only remove the new network"
  let savedTimeout = newFake(NeverJoins)
  discard savedTimeout.expectFailure(ConnectRequest(savedId: 1, timeoutMs: 5000))
  doAssert "DISABLE_NETWORK 1" notin savedTimeout.log or savedTimeout.networks[1].disabled
  for unsupported in [EnterpriseSecurity, Wpa3OnlySecurity, WepSecurity]:
    let fake = newFake()
    discard fake.expectFailure(ConnectRequest(savedId: -1, ssid: "Office",
      security: unsupported, timeoutMs: 1000))
    doAssert fake.log.len == 3, "unsupported networks change nothing"
  let shortPassword = newFake()
  discard shortPassword.expectFailure(ConnectRequest(savedId: -1, ssid: "Café",
    security: PersonalSecurity, password: "short", timeoutMs: 1000))
  for command in shortPassword.log: doAssert not command.startsWith("ADD_NETWORK")
  for version in ["1.1", "FAIL", "UNKNOWN COMMAND", ""]:
    let old = newFake()
    old.version = version
    doAssert "older than 2.0" in old.expectFailure(request)
    doAssert old.log == @["GET version"], "unsupported daemons are never changed"

proc protectedFile(path, contents: string) =
  ## Write a fixture configuration with mode 0600.
  writeFile(path, contents)
  setFilePermissions(path, {fpUserRead, fpUserWrite})

proc leftovers(directory: string): seq[string] =
  ## List private copies left in a configuration directory.
  for kind, entry in walkDir(directory):
    if ".mono-retro-" in entry.extractFilename: result.add entry

proc testPersistence() =
  ## Replace the configuration atomically, keep its bytes and refuse unsafe files.
  let
    directory = createTempDir("mono-retro-wifi-", "")
    path = directory / "wpa.conf"
    original = "ctrl_interface=/run/wpa_supplicant\nupdate_config=0\n# opaque \xff\x00 bytes"
    owner = getuid()
    profile = networkBlock("Café", PersonalSecurity, PasswordKey)
  defer: removeDir(directory)
  protectedFile(path, original)
  saveNetworkBlock(path, profile, owner)
  let contents = readFile(path)
  doAssert contents == original & profile
  doAssert getFilePermissions(path) == {fpUserRead, fpUserWrite}
  var info: Stat
  doAssert stat(path.cstring, info) == 0 and info.st_uid == owner and info.st_nlink == 1
  doAssert directory.leftovers().len == 0
  for step in PersistStep:
    var raised = false
    try:
      saveNetworkBlock(path, profile, owner, proc(at: PersistStep) =
        if at == step: raise newException(IOError, "injected " & $step))
    except IOError as error:
      raised = true
      doAssert "injected" in error.msg
    doAssert raised, $step
    doAssert readFile(path) == contents, $step
    doAssert directory.leftovers().len == 0, $step
  var raised = false
  try:
    saveNetworkBlock(path, profile, owner, proc(at: PersistStep) =
      if at == ReplaceStep:
        protectedFile(directory / "other.conf", "replacement\n")
        moveFile(directory / "other.conf", path))
  except IOError as error:
    raised = true
    doAssert "changed while saving" in error.msg
  doAssert raised and readFile(path) == "replacement\n" and directory.leftovers().len == 0
  protectedFile(path, contents)
  for (name, setup) in [("wrong mode", 0), ("symlink", 1), ("hard link", 2), ("wrong owner", 3)]:
    raised = false
    try:
      case setup
      of 0:
        setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead})
        saveNetworkBlock(path, "x", owner)
      of 1:
        setFilePermissions(path, {fpUserRead, fpUserWrite})
        createSymlink(path, directory / "link.conf")
        saveNetworkBlock(directory / "link.conf", "x", owner)
      of 2:
        createHardlink(path, directory / "hard.conf")
        try: saveNetworkBlock(path, "x", owner)
        finally: removeFile(directory / "hard.conf")
      else: saveNetworkBlock(path, "x", owner + 1)
    except CatchableError: raised = true
    doAssert raised, name
    doAssert readFile(path) == contents, name
    doAssert directory.leftovers().len == 0, name

var
  fakeServer: FakeWpa
  statusDelayMs, dropStatus: Atomic[int]
  connectWaiting: Atomic[bool]

proc serve(directory: string) {.thread.} =
  ## Answer datagrams on a fake control socket until told to stop. STATUS
  ## replies during a join can be delayed or dropped, and SCAN sends a
  ## completion event to an attached client.
  {.cast(gcsafe).}:
    let server = posix.socket(AF_UNIX, SOCK_DGRAM, 0)
    var address: Sockaddr_un
    address.sun_family = AF_UNIX.TSa_Family
    let path = directory / "wlan0"
    for index, character in path: address.sun_path[index] = character
    doAssert bindSocket(server, cast[ptr SockAddr](addr address), sizeof(address).SockLen) == 0
    var
      buffer = newString(4096)
      monitor: Sockaddr_un
      monitorLength: SockLen = 0
    while true:
      var
        peer: Sockaddr_un
        length = sizeof(peer).SockLen
      let received = recvfrom(server, addr buffer[0], buffer.len, 0,
        cast[ptr SockAddr](addr peer), addr length)
      if received <= 0: break
      let command = buffer[0 ..< received]
      if command == "STOP": break
      var reply = ""
      case command
      of "ATTACH":
        monitor = peer
        monitorLength = length
        reply = "OK\n"
      of "DETACH":
        monitorLength = 0
        reply = "OK\n"
      else:
        if command == "STATUS" and fakeServer.selected >= 3:
          connectWaiting.store(true)
          if dropStatus.load() > 0:
            dropStatus.atomicDec()
            continue
          if statusDelayMs.load() > 0: sleep(statusDelayMs.load())
        reply = fakeServer.handle(command)
      discard sendto(server, reply.cstring, reply.len, 0, cast[ptr SockAddr](addr peer), length)
      if command == "SCAN" and monitorLength > 0:
        let event = "<2>CTRL-EVENT-SCAN-RESULTS "
        discard sendto(server, event.cstring, event.len, 0, cast[ptr SockAddr](addr monitor),
          monitorLength)
    discard posix.close(server)

proc runCancelledConnect(worker, directory, configPath: string): JsonNode =
  ## Start a join that never completes, send SIGTERM while the worker waits for
  ## a STATUS reply, and return the published result.
  let resultPath = directory / "cancel.json"
  connectWaiting.store(false)
  let process = startProcess(worker, args = ["connect", "--control-dir:" & directory,
    "--ssid-hex:" & "Café".ssidToHex(), "--security:personal", "--password-stdin",
    "--config-file:" & configPath, "--result:" & resultPath], options = {})
  process.inputStream.write(Password & "\n")
  process.inputStream.close()
  var waited = 0
  while not connectWaiting.load() and waited < 10000:
    sleep(20)
    waited += 20
  doAssert connectWaiting.load(), "worker reached the join wait"
  sleep(300)
  process.terminate()
  doAssert process.waitForExit(30000) == 1
  process.close()
  let output = readFile(resultPath)
  assertSecretAbsent(output)
  result = parseJson(output)
  doAssert result["cancelled"].getBool(), output

proc testWorker() =
  ## Drive the real worker and socket transport, passing the password on stdin.
  let
    directory = createTempDir("mono-retro-wifi-worker-", "")
    worker = absolutePath("build/mono-retro-wifi")
    configPath = directory / "wpa.conf"
    resultPath = directory / "result.json"
    original = "update_config=0\n"
  defer: removeDir(directory)
  protectedFile(configPath, original)
  doAssert execCmd("nim c --hints:off -o:" & quoteShell(worker) & " src/wificli.nim") == 0
  fakeServer = newFake()
  var thread: Thread[string]
  createThread(thread, serve, directory)
  sleep(100)
  var scan = parseJson(execProcess(worker, args = ["scan", "--cached", "--control-dir:" & directory],
    options = {}))
  doAssert scan["networks"].len == 7 and not scan["fresh"].getBool()
  doAssert "ADD_NETWORK" notin fakeServer.log and "SCAN" notin fakeServer.log
  scan = parseJson(execProcess(worker, args = ["scan", "--control-dir:" & directory], options = {}))
  doAssert scan["fresh"].getBool() and "SCAN" in fakeServer.log
  for command in fakeServer.log:
    doAssert command.split(' ')[0] in ["PING", "STATUS", "LIST_NETWORKS", "SCAN", "SCAN_RESULTS"]
  let arguments = @["connect", "--control-dir:" & directory, "--interface:wlan0",
    "--ssid-hex:" & "Café".ssidToHex(), "--security:personal", "--password-stdin",
    "--config-file:" & configPath, "--result:" & resultPath]
  assertSecretAbsent(arguments)
  let process = startProcess(worker, args = arguments, options = {})
  process.inputStream.write(Password & "\n")
  process.inputStream.close()
  doAssert process.waitForExit(30000) == 0
  process.close()
  let output = readFile(resultPath)
  assertSecretAbsent(output)
  let connected = parseJson(output)
  doAssert connected["connected"].getBool() and connected["ipAddress"].getStr() == "198.51.100.7"
  doAssert connected["addressChanged"].getBool() and not connected.hasKey("statusError")
  if getuid() == 0:
    doAssert connected["saved"].getBool(), output
    doAssert readFile(configPath) == original & networkBlock("Café", PersonalSecurity, PasswordKey)
  else:
    # The configuration must be root-owned; an ordinary user's fixture is refused honestly.
    doAssert not connected["saved"].getBool() and "unexpected owner" in connected["saveError"].getStr()
    doAssert readFile(configPath) == original
  doAssert directory.leftovers().len == 0
  # SIGTERM while a STATUS reply is delayed: the interrupted wait resumes and rollback runs.
  protectedFile(configPath, original)
  fakeServer = newFake(NeverJoins)
  statusDelayMs.store(1500)
  let delayed = runCancelledConnect(worker, directory, configPath)
  doAssert delayed["error"].getStr() == "Connection cancelled", $delayed
  statusDelayMs.store(0)
  fakeServer.assertRestored()
  doAssert readFile(configPath) == original
  # SIGTERM while a STATUS reply is lost: the request times out, a fresh endpoint
  # is opened and rollback still reaches the daemon.
  fakeServer = newFake(NeverJoins)
  dropStatus.store(1)
  let dropped = runCancelledConnect(worker, directory, configPath)
  doAssert "did not answer STATUS" in dropped["error"].getStr()
  fakeServer.assertRestored()
  doAssert readFile(configPath) == original and directory.leftovers().len == 0
  var invalid = execCmdEx(quoteShell(worker) & " status --interface:../etc")
  doAssert invalid.exitCode != 0 and "Invalid network interface" in invalid.output
  invalid = execCmdEx(quoteShell(worker) & " status --control-dir:" & quoteShell(directory / "missing"))
  doAssert invalid.exitCode != 0 and "unavailable" in invalid.output
  let badOption = directory / "bad.json"
  invalid = execCmdEx(quoteShell(worker) & " status --result:" & quoteShell(badOption) & " --bogus")
  doAssert invalid.exitCode != 0 and "Unknown option" in parseFile(badOption)["error"].getStr()
  let stopper = posix.socket(AF_UNIX, SOCK_DGRAM, 0)
  var address: Sockaddr_un
  address.sun_family = AF_UNIX.TSa_Family
  for index, character in directory / "wlan0": address.sun_path[index] = character
  discard sendto(stopper, "STOP".cstring, 4, 0, cast[ptr SockAddr](addr address), sizeof(address).SockLen)
  discard posix.close(stopper)
  joinThread(thread)

testParsing()
testKeys()
testAddresses()
testNewNetworkSuccess()
testSameAddress()
testSavedReuse()
testFailures()
testPersistence()
testWorker()
