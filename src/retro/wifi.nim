## wpa_supplicant control-protocol client logic.
##
## Everything here talks through an injected `WpaTransport`, so the same code
## drives the real control socket and test fakes. Passphrases are turned into
## a 64-digit hex key that is only sent in a single `SET_NETWORK <id> psk`
## command and written to the configuration; neither appears in progress,
## errors or results. Saved keys are never requested from the daemon.

import
  std/[json, openssl, strutils, unicode]

type
  WpaTransport* = proc(command: string): string {.closure.}
    ## Send one control command and return the daemon's complete reply.
  WifiSecurity* = enum
    OpenSecurity, PersonalSecurity, Wpa3OnlySecurity, EnterpriseSecurity,
    WepSecurity, OweSecurity
  WifiNetwork* = object
    ssid*, ssidHex*, flags*: string
    signal*, frequency*, savedId*: int
    security*: WifiSecurity
    current*: bool
  SavedNetwork* = object
    id*: int
    ssid*, flags*: string
  WifiStatus* = object
    state*, ssid*, ipAddress*, keyManagement*: string
    networkId*: int
  ConnectRequest* = object
    ## `savedId` selects an existing runtime network; otherwise `ssid` (raw
    ## bytes) and `security` describe a new one.
    savedId*: int
    ssid*: string
    security*: WifiSecurity
    password*: string
    timeoutMs*: int
  ConnectHooks* = object
    progress*: proc(message: string) {.closure.}
    cancelled*: proc(): bool {.closure.}
    sleep*: proc(milliseconds: int) {.closure.}
    elapsedMs*: proc(): int {.closure.}
    persist*: proc(networkBlock: string) {.closure.}
  ConnectResult* = object
    ## `ipAddress` is the observed interface address, not proof of Internet
    ## access. `addressChanged` is false when switching networks kept the
    ## previous address; `readiness` then explains what is unconfirmed.
    ssid*, ipAddress*, saveError*, readiness*: string
    networkId*: int
    added*, saved*, reusedProfile*, addressChanged*: bool
  WifiCancelled* = object of CatchableError

const
  SupportedSecurity* = {OpenSecurity, PersonalSecurity}
  SecurityNames*: array[WifiSecurity, string] = ["Open", "WPA/WPA2 Personal",
    "WPA3-only (not supported yet)", "Enterprise (not supported)",
    "WEP (not supported)", "Enhanced Open (not supported)"]
  PollIntervalMs = 500
  FailureCheckEvery = 4
  StableCompletedPolls = 2
  MinimumPassphrase = 8
  MaximumPassphrase = 63
  RawPskLength* = 64
  PskBytes = 32
  PskIterations = 4096
  SameAddressGraceMs = 6000
  MinimumManagerMajor = 2

proc PKCS5_PBKDF2_HMAC_SHA1(pass: cstring, passlen: cint, salt: ptr uint8, saltlen: cint,
  iter, keylen: cint, output: ptr uint8): cint {.cdecl, dynlib: DLLUtilName, importc.}

proc printfDecode*(text: string): string =
  ## Decode the escaping wpa_supplicant uses for SSIDs in text replies.
  var index = 0
  while index < text.len:
    let character = text[index]
    if character != '\\' or index + 1 >= text.len:
      result.add character
      inc index
      continue
    let next = text[index + 1]
    index += 2
    case next
    of 'n': result.add '\n'
    of 'r': result.add '\r'
    of 't': result.add '\t'
    of 'e': result.add '\e'
    of 'x':
      if index + 1 < text.len and text[index] in HexDigits and text[index + 1] in HexDigits:
        result.add char(parseHexInt(text[index .. index + 1]))
        index += 2
      else: result.add 'x'
    of '0' .. '7':
      var
        value = ord(next) - ord('0')
        digits = 1
      while digits < 3 and index < text.len and text[index] in {'0' .. '7'}:
        value = value * 8 + ord(text[index]) - ord('0')
        inc index
        inc digits
      result.add char(value and 255)
    else: result.add next

proc ssidToHex*(ssid: string): string =
  ## Encode raw SSID bytes as lowercase hex for unquoted control and config values.
  for character in ssid: result.add toHex(ord(character), 2).toLowerAscii()

proc hexToSsid*(hex: string): string =
  ## Decode a hex SSID. Raises ValueError for malformed or oversized input.
  if hex.len == 0 or hex.len mod 2 != 0 or hex.len > 64:
    raise newException(ValueError, "SSID must be 1-32 bytes of hex")
  for index in countup(0, hex.high, 2):
    if hex[index] notin HexDigits or hex[index + 1] notin HexDigits:
      raise newException(ValueError, "SSID must be 1-32 bytes of hex")
    result.add char(parseHexInt(hex[index .. index + 1]))

proc displaySsid*(ssid: string): string =
  ## Make raw SSID bytes safe to paint: invalid UTF-8 and controls become "?".
  var index = 0
  while index < ssid.len:
    let length = max(1, ssid.runeLenAt(index))
    let piece = ssid[index ..< min(ssid.len, index + length)]
    let rune = if piece.validateUtf8() == -1: piece.runeAt(0) else: Rune(0xfffd)
    if rune.int < 0x20 or rune.int == 0x7f or rune.int == 0xfffd: result.add '?'
    else: result.add piece
    index += length

proc classify*(flags: string): WifiSecurity =
  ## Map scan flags such as "[WPA2-PSK-CCMP][ESS]" to a supported security mode.
  if "PSK" in flags: PersonalSecurity
  elif "EAP" in flags: EnterpriseSecurity
  elif "SAE" in flags: Wpa3OnlySecurity
  elif "OWE" in flags: OweSecurity
  elif "WEP" in flags: WepSecurity
  elif "WPA" in flags or "RSN" in flags: EnterpriseSecurity
  else: OpenSecurity

proc commandName(command: string): string =
  ## Name a command in errors without echoing arguments that may be secret.
  let parts = command.split(' ')
  if parts.len >= 3 and parts[0] == "SET_NETWORK": parts[0] & " " & parts[2] else: parts[0]

proc request*(transport: WpaTransport, command: string, secret = false): string =
  ## Send a command and raise IOError for FAIL or UNKNOWN COMMAND replies.
  ## Replies to secret-bearing commands are never quoted in errors.
  result = transport(command)
  let reply = result.strip()
  if reply.startsWith("FAIL") or reply == "UNKNOWN COMMAND":
    raise newException(IOError, "wpa_supplicant rejected " & command.commandName() &
      (if secret: "" else: ": " & reply))

proc expectOk(transport: WpaTransport, command: string, secret = false) =
  ## Require an OK reply from a state-changing command.
  let reply = transport.request(command, secret).strip()
  if reply != "OK":
    raise newException(IOError, "wpa_supplicant rejected " & command.commandName() &
      (if secret: "" else: ": " & reply))

proc requireMutationSupport*(transport: WpaTransport) =
  ## Refuse configuration changes unless the daemon reports wpa_supplicant 2.0
  ## or newer, which provides `ENABLE_NETWORK <id> no-connect` and `GET version`.
  let reply = transport("GET version").strip()
  var major = 0
  var digits = 0
  while digits < reply.len and reply[digits] in Digits: inc digits
  if digits > 0 and digits <= 3 and digits < reply.len and reply[digits] == '.':
    major = parseInt(reply[0 ..< digits])
  if major < MinimumManagerMajor:
    raise newException(IOError,
      "Wi-Fi manager version is unknown or older than 2.0; connecting is disabled")

proc parseStatus*(reply: string): WifiStatus =
  ## Parse STATUS key=value lines; SSIDs are decoded to raw bytes.
  result.networkId = -1
  for line in reply.splitLines():
    let separator = line.find('=')
    if separator <= 0: continue
    let
      key = line[0 ..< separator]
      value = line[separator + 1 .. ^1]
    case key
    of "wpa_state": result.state = value
    of "ssid": result.ssid = printfDecode(value)
    of "ip_address": result.ipAddress = value
    of "key_mgmt": result.keyManagement = value
    of "id": result.networkId = parseInt(value)
    else: discard

proc parseNetworks*(reply: string): seq[SavedNetwork] =
  ## Parse LIST_NETWORKS. Passwords are not part of this reply.
  let lines = reply.splitLines()
  for number, line in lines:
    if number == 0 or line.len == 0: continue
    let fields = line.split('\t')
    if fields.len < 2: continue
    result.add SavedNetwork(id: parseInt(fields[0]), ssid: printfDecode(fields[1]),
      flags: if fields.len >= 4: fields[3] else: "")

proc parseScan*(reply: string, saved: seq[SavedNetwork] = @[],
    status = WifiStatus(networkId: -1)): seq[WifiNetwork] =
  ## Parse SCAN_RESULTS, keep the strongest entry per SSID and skip hidden networks.
  let lines = reply.splitLines()
  for number, line in lines:
    if number == 0 or line.len == 0: continue
    let fields = line.split('\t')
    if fields.len < 5: continue
    let ssid = printfDecode(fields[4 .. ^1].join("\t"))
    if ssid.len == 0 or ssid.len > 32 or ssid.allCharsInSet({'\0'}): continue
    var network = WifiNetwork(ssid: ssid, ssidHex: ssid.ssidToHex(), flags: fields[3],
      security: classify(fields[3]), savedId: -1)
    network.frequency = parseInt(fields[1])
    network.signal = parseInt(fields[2])
    for entry in saved:
      if entry.ssid == ssid:
        network.savedId = entry.id
        network.current = "[CURRENT]" in entry.flags
    if status.state == "COMPLETED" and status.ssid == ssid: network.current = true
    var replaced = false
    for existing in result.mitems:
      if existing.ssid == ssid:
        replaced = true
        if network.signal > existing.signal: existing = network
    if not replaced: result.add network

proc isRawPsk(password: string): bool =
  ## Report whether a password is a 64-digit hex WPA key.
  password.len == RawPskLength and password.allCharsInSet(HexDigits)

proc validatePassword*(password: string) =
  ## Accept an 8-63 character printable ASCII passphrase or a 64-digit hex key.
  ## Raises ValueError without including the password.
  if not password.isRawPsk():
    if password.len < MinimumPassphrase or password.len > MaximumPassphrase:
      raise newException(ValueError,
        "Use an 8-63 character password or a 64-digit hex key")
    for character in password:
      if character < ' ' or character > '~':
        raise newException(ValueError, "WPA passwords may use printable ASCII only")

proc pskHex*(password, ssid: string): string =
  ## Return the WPA key as 64 lowercase hex digits. Passphrases are derived with
  ## PBKDF2-HMAC-SHA1(passphrase, SSID, 4096, 32) from the system libcrypto.
  validatePassword(password)
  if password.isRawPsk(): return password.toLowerAscii()
  var key: array[PskBytes, uint8]
  if PKCS5_PBKDF2_HMAC_SHA1(password.cstring, password.len.cint, cast[ptr uint8](ssid.cstring),
      ssid.len.cint, PskIterations, PskBytes, addr key[0]) != 1:
    raise newException(IOError, "Could not derive the WPA key")
  for value in key: result.add toHex(value.int, 2).toLowerAscii()
  zeroMem(addr key[0], key.len)

proc networkBlock*(ssid: string, security: WifiSecurity, psk: string): string =
  ## Format a wpa_supplicant.conf network block for a new profile. `psk` is the
  ## 64-digit hex key from `pskHex`.
  result = "\nnetwork={\n\tssid=" & ssid.ssidToHex() & "\n"
  if security == PersonalSecurity:
    result &= "\tkey_mgmt=WPA-PSK\n\tpsk=" & psk & "\n"
  else:
    result &= "\tkey_mgmt=NONE\n"
  result &= "}\n"

proc currentStatus*(transport: WpaTransport): WifiStatus =
  ## Query the daemon's connection status.
  parseStatus(transport.request("STATUS"))

proc savedNetworks*(transport: WpaTransport): seq[SavedNetwork] =
  ## Query runtime networks without their secrets.
  parseNetworks(transport.request("LIST_NETWORKS"))

proc enabled(network: SavedNetwork): bool =
  ## Report whether a network was eligible for automatic selection.
  "[DISABLED]" notin network.flags

proc usableAddress*(address: string): bool =
  ## Accept a strict dotted-quad IPv4 address that is not unspecified,
  ## loopback, link-local, multicast or reserved.
  let parts = address.split('.')
  var octets: seq[int]
  if parts.len == 4:
    for part in parts:
      if part.len in 1 .. 3 and part.allCharsInSet(Digits) and (part.len == 1 or part[0] != '0'):
        octets.add parseInt(part)
  result = octets.len == 4 and octets[0] in 1 .. 223 and octets[0] != 127 and
    octets[1] <= 255 and octets[2] <= 255 and octets[3] <= 255 and
    not (octets[0] == 169 and octets[1] == 254)

proc restore(transport: WpaTransport, prior: seq[SavedNetwork], priorCurrent, target: int,
    added, selected: bool): string =
  ## Undo a connection attempt and report problems as text. Before selection
  ## only a newly added network is removed. After selection the previous network
  ## is selected again and other profiles are re-enabled without reconnecting.
  var problems: seq[string]
  template attempt(command: string) =
    try: transport.expectOk(command)
    except CatchableError as error: problems.add error.msg
  if added: attempt("REMOVE_NETWORK " & $target)
  if selected:
    if priorCurrent >= 0: attempt("SELECT_NETWORK " & $priorCurrent)
    for network in prior:
      if network.id == priorCurrent: continue
      if network.enabled: attempt("ENABLE_NETWORK " & $network.id & " no-connect")
      elif network.id == target and priorCurrent < 0: attempt("DISABLE_NETWORK " & $network.id)
  if added or selected:
    try:
      let now = transport.savedNetworks()
      for network in prior:
        var found = false
        for entry in now:
          if entry.id == network.id:
            found = true
            if entry.enabled != network.enabled: problems.add "network " & $network.id &
              (if network.enabled: " is still disabled" else: " is still enabled")
        if not found: problems.add "network " & $network.id & " is missing"
      if added:
        for entry in now:
          if entry.id == target: problems.add "temporary network " & $target & " remains"
    except CatchableError as error: problems.add error.msg
  problems.join("; ")

proc connect*(transport: WpaTransport, connection: ConnectRequest,
    hooks: ConnectHooks): ConnectResult =
  ## Select or add a network, wait for authorization and a usable address,
  ## re-enable other profiles without reconnecting, confirm the connection
  ## held, then persist new profiles. Failure, timeout and cancellation restore
  ## the previous selection and enabled set before raising.
  transport.requireMutationSupport()
  let
    prior = transport.savedNetworks()
    before = transport.currentStatus()
  var priorCurrent = -1
  for network in prior:
    if "[CURRENT]" in network.flags: priorCurrent = network.id
  if priorCurrent < 0 and before.state == "COMPLETED": priorCurrent = before.networkId
  var
    target = connection.savedId
    psk = ""
  if target >= 0:
    var found = false
    for network in prior:
      if network.id == target:
        found = true
        result.ssid = network.ssid
    if not found: raise newException(ValueError, "Saved network " & $target & " no longer exists")
    result.reusedProfile = true
  else:
    if connection.security notin SupportedSecurity:
      raise newException(ValueError, SecurityNames[connection.security])
    if connection.ssid.len == 0 or connection.ssid.len > 32:
      raise newException(ValueError, "SSID must be 1-32 bytes")
    result.ssid = connection.ssid
    for network in prior:
      if network.ssid == connection.ssid: target = network.id
    if target >= 0:
      if connection.password.len > 0:
        raise newException(ValueError, displaySsid(connection.ssid) &
          " already has a saved profile; choose it from the list to use the saved password")
      result.reusedProfile = true
    else:
      if connection.security == PersonalSecurity: psk = pskHex(connection.password, connection.ssid)
      let reply = transport.request("ADD_NETWORK").strip()
      if reply.len == 0 or reply.len > 9 or not reply.allCharsInSet(Digits):
        raise newException(IOError, "wpa_supplicant did not return a network id")
      target = parseInt(reply)
      result.added = true
      try:
        transport.expectOk("SET_NETWORK " & $target & " ssid " & connection.ssid.ssidToHex())
        if connection.security == PersonalSecurity:
          transport.expectOk("SET_NETWORK " & $target & " key_mgmt WPA-PSK")
          transport.expectOk("SET_NETWORK " & $target & " psk " & psk, secret = true)
        else:
          transport.expectOk("SET_NETWORK " & $target & " key_mgmt NONE")
      except CatchableError as error:
        let problems = transport.restore(prior, priorCurrent, target, true, false)
        if problems.len > 0: error.msg &= " (restore incomplete: " & problems & ")"
        raise error
  result.networkId = target
  let
    name = displaySsid(result.ssid)
    switching = priorCurrent != target and before.ipAddress.usableAddress()
  var selected = false
  try:
    hooks.progress("Connecting to " & name)
    selected = true
    transport.expectOk("SELECT_NETWORK " & $target)
    var
      polls = 0
      completed = 0
      sameAddressSince = -1
      lastState = ""
    while true:
      if hooks.cancelled(): raise newException(WifiCancelled, "Connection cancelled")
      if hooks.elapsedMs() >= connection.timeoutMs:
        raise newException(IOError, "Timed out connecting to " & name)
      hooks.sleep(PollIntervalMs)
      inc polls
      let status = transport.currentStatus()
      if status.state != lastState:
        lastState = status.state
        hooks.progress(case status.state
          of "COMPLETED": "Joined " & name & "; waiting for an address"
          of "4WAY_HANDSHAKE", "GROUP_HANDSHAKE": "Checking password for " & name
          of "ASSOCIATING", "ASSOCIATED", "AUTHENTICATING": "Joining " & name
          else: "Looking for " & name)
      if status.state == "COMPLETED" and status.networkId == target and
          status.ipAddress.usableAddress():
        inc completed
        let fresh = not switching or status.ipAddress != before.ipAddress
        if not fresh and sameAddressSince < 0: sameAddressSince = hooks.elapsedMs()
        if completed >= StableCompletedPolls and (fresh or
            hooks.elapsedMs() - sameAddressSince >= SameAddressGraceMs):
          result.ipAddress = status.ipAddress
          result.addressChanged = fresh
          break
      else:
        completed = 0
        sameAddressSince = -1
      if polls mod FailureCheckEvery == 0:
        for network in transport.savedNetworks():
          if network.id == target and "[TEMP-DISABLED]" in network.flags:
            raise newException(IOError, "Could not join " & name &
              (if connection.security == PersonalSecurity and result.added: "; check the password" else: ""))
    for network in prior:
      if network.id != target and network.enabled:
        transport.expectOk("ENABLE_NETWORK " & $network.id & " no-connect")
    let check = transport.currentStatus()
    if check.state != "COMPLETED" or check.networkId != target or check.ipAddress != result.ipAddress:
      raise newException(IOError, name & " did not stay connected after restoring other profiles")
  except CatchableError as error:
    let problems = transport.restore(prior, priorCurrent, target, result.added, selected)
    if problems.len > 0: error.msg &= " (restore incomplete: " & problems & ")"
    if hooks.cancelled() and not (error of WifiCancelled):
      raise newException(WifiCancelled, "Connection cancelled: " & error.msg)
    raise error
  if not result.addressChanged:
    result.readiness = "Same address as the previous network; network readiness is unconfirmed"
  if result.added:
    try:
      hooks.persist(networkBlock(connection.ssid, connection.security, psk))
      result.saved = true
    except CatchableError as error:
      result.saveError = "Connected, but the profile was not saved: " & error.msg
  for index in 0 ..< psk.len: psk[index] = '\0'
  hooks.progress("Connected to " & name & " (" & result.ipAddress & ")")

proc toJson*(network: WifiNetwork): JsonNode =
  ## Describe a scanned network without raw SSID bytes.
  %*{"ssid": displaySsid(network.ssid), "ssidHex": network.ssidHex,
    "signal": network.signal, "frequency": network.frequency,
    "security": $network.security, "savedId": network.savedId, "current": network.current}

proc toJson*(status: WifiStatus): JsonNode =
  ## Describe the connection without raw SSID bytes.
  %*{"state": status.state, "ssid": displaySsid(status.ssid), "ipAddress": status.ipAddress,
    "keyManagement": status.keyManagement, "networkId": status.networkId}

proc networkFromJson*(node: JsonNode): WifiNetwork =
  ## Read a network produced by `toJson`.
  WifiNetwork(ssid: node["ssid"].getStr(), ssidHex: node["ssidHex"].getStr(),
    signal: node["signal"].getInt(), frequency: node["frequency"].getInt(),
    security: parseEnum[WifiSecurity](node["security"].getStr()),
    savedId: node["savedId"].getInt(-1), current: node["current"].getBool())

proc statusFromJson*(node: JsonNode): WifiStatus =
  ## Read a status produced by `toJson`.
  WifiStatus(state: node["state"].getStr(), ssid: node["ssid"].getStr(),
    ipAddress: node["ipAddress"].getStr(), keyManagement: node["keyManagement"].getStr(),
    networkId: node["networkId"].getInt(-1))
