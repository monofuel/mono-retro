import
  std/[json, monotimes, os, parseopt, posix, strutils, times],
  retro/[wifi, wpasocket]

const
  Help = """Usage: mono-retro-wifi COMMAND [options]
Commands:
  status          Show the current connection. Read-only.
  scan            Request a scan, wait for it to finish, and list networks.
                  Changes no configuration.
  scan --cached   List the daemon's last scan results without scanning.
  connect         Join --network:ID (saved) or --ssid-hex:HEX (new).
Options: --interface:wlan0 --control-dir:/run/wpa_supplicant
  --security:open|personal --password-stdin --timeout:SECONDS
  --config-file:PATH --progress:FILE --result:FILE
New personal networks read an 8-63 character password or a 64-digit hex key
from the first line of standard input. New profiles are added to the running
daemon's -c configuration only after the network is authorized, has an address
and stays selected. Connecting requires wpa_supplicant 2.0 or newer.
"""
  ScanWaitMs = 15000
  DefaultTimeoutSeconds = 45
  ScanEvents = ["CTRL-EVENT-SCAN-RESULTS", "CTRL-EVENT-SCAN-FAILED"]

var cancelRequested {.global.}: bool

proc onTerminate(signal: cint) {.noconv.} =
  ## Ask the connect loop to stop and restore the previous connection.
  cancelRequested = true

proc publish(path: string, node: JsonNode) =
  ## Replace a JSON file atomically so readers never see partial output.
  writeFile(path & ".tmp", $node & "\n")
  moveFile(path & ".tmp", path)

proc scanNetworks(control: WpaControl, interfaceName, controlDirectory: string,
    cached: bool): JsonNode =
  ## Optionally trigger a scan and wait for the daemon's completion event, then
  ## report results, saved ids and status. `fresh` is true only when a scan
  ## was confirmed complete; otherwise the list is the daemon's earlier results.
  let transport: WpaTransport = proc(command: string): string = control.request(command)
  var fresh = false
  if not cached:
    let events = openWpaControl(interfaceName, controlDirectory)
    try:
      events.attach()
      # FAIL-BUSY means a scan is already pending; its completion event still counts.
      let reply = control.request("SCAN").strip()
      if reply in ["OK", "FAIL-BUSY"]:
        let event = events.waitForEvent(ScanEvents, ScanWaitMs, proc(): bool = cancelRequested)
        fresh = event.startsWith(ScanEvents[0])
      if events.request("DETACH").strip() != "OK":
        raise newException(IOError, "Wi-Fi manager refused to stop scan monitoring")
    finally:
      events.close()
  let
    status = transport.currentStatus()
    saved = transport.savedNetworks()
    networks = parseScan(transport.request("SCAN_RESULTS"), saved, status)
  result = %*{"status": status.toJson(), "fresh": fresh, "networks": newJArray()}
  for network in networks: result["networks"].add network.toJson()

proc main() =
  ## Run one Wi-Fi command and report JSON on stdout or to --result.
  var
    command, progressPath, resultPath, ssidHex, configFile, password = ""
    interfaceName = DefaultInterface
    controlDirectory = DefaultControlDirectory
    security = PersonalSecurity
    savedId = -1
    timeout = DefaultTimeoutSeconds
    cached, passwordStdin = false
    output: JsonNode
    code = 0
    control: WpaControl
  signal(SIGTERM, onTerminate)
  signal(SIGINT, onTerminate)
  let started = getMonoTime()
  proc progress(message: string) =
    ## Publish progress text, which never contains secrets.
    if progressPath.len > 0: progressPath.publish(%*{"message": message})
  try:
    for kind, key, value in getopt():
      case kind
      of cmdArgument:
        if command.len == 0: command = key
      of cmdLongOption, cmdShortOption:
        case key
        of "help", "h":
          stdout.write Help
          quit(0)
        of "interface": interfaceName = value
        of "control-dir": controlDirectory = value
        of "network": savedId = parseInt(value)
        of "ssid-hex": ssidHex = value
        of "security": security = if value == "open": OpenSecurity elif value == "personal": PersonalSecurity
          else: raise newException(ValueError, "--security must be open or personal")
        of "password-stdin": passwordStdin = true
        of "timeout": timeout = parseInt(value)
        of "config-file": configFile = value
        of "progress": progressPath = value
        of "result": resultPath = value
        of "cached": cached = true
        else: raise newException(ValueError, "Unknown option --" & key)
      of cmdEnd: discard
    if command notin ["status", "scan", "connect"]:
      stderr.write Help
      raise newException(ValueError, "Unknown command")
    validateInterface(interfaceName)
    if passwordStdin: password = stdin.readLine()
    control = openWpaControl(interfaceName, controlDirectory)
    let transport: WpaTransport = proc(command: string): string = control.request(command)
    if transport("PING").strip() != "PONG": raise newException(IOError, "Wi-Fi manager did not answer PING")
    case command
    of "status": output = %*{"status": transport.currentStatus().toJson()}
    of "scan":
      progress("Scanning for networks")
      output = control.scanNetworks(interfaceName, controlDirectory, cached)
    else:
      if savedId < 0 and ssidHex.len == 0:
        raise newException(ValueError, "connect needs --network or --ssid-hex")
      let hooks = ConnectHooks(progress: progress,
        cancelled: proc(): bool = cancelRequested,
        sleep: proc(milliseconds: int) = sleep(milliseconds),
        elapsedMs: proc(): int = int((getMonoTime() - started).inMilliseconds),
        persist: proc(networkBlock: string) =
          let path = if configFile.len > 0: configFile else: discoverConfigPath(interfaceName)
          if path.len == 0: raise newException(IOError, "the wpa_supplicant configuration file is unknown")
          saveNetworkBlock(path, networkBlock))
      let connected = transport.connect(ConnectRequest(savedId: savedId,
        ssid: if ssidHex.len > 0: hexToSsid(ssidHex) else: "", security: security,
        password: password, timeoutMs: timeout * 1000), hooks)
      output = %*{"connected": true, "ssid": displaySsid(connected.ssid),
        "ipAddress": connected.ipAddress, "addressChanged": connected.addressChanged,
        "readiness": connected.readiness, "networkId": connected.networkId,
        "added": connected.added, "reusedProfile": connected.reusedProfile,
        "saved": connected.saved, "saveError": connected.saveError}
      # A later status failure must not turn a confirmed connection into a failed join.
      try: output["status"] = transport.currentStatus().toJson()
      except CatchableError as error: output["statusError"] = %error.msg
  except CatchableError as error:
    output = %*{"error": error.msg, "cancelled": error of WifiCancelled}
    code = 1
  finally:
    for index in 0 ..< password.len: password[index] = '\0'
    control.close()
  if resultPath.len > 0: resultPath.publish(output)
  else: echo output.pretty()
  quit(code)

when isMainModule:
  main()
