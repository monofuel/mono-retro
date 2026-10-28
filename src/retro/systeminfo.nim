import
  std/[algorithm, json, options, os, osproc, posix, streams, strutils]

type
  BatteryReading* = object
    name*, status*, error*: string
    percent*: int
    currentMicroamps*: Option[int]
  BatteryFlow* = enum
    UnknownFlow, ChargingFlow, DischargingFlow, FullFlow, IdleFlow
  PowerStatus* = object
    batteries*: seq[BatteryReading]
    selected*: string
    currentSupply*: string
    external*: bool

proc readValue(path: string): string =
  ## Read an optional OS attribute without inventing a value.
  if fileExists(path): readFile(path).strip() else: ""

proc readPower*(selected: string, root = "/sys/class/power_supply",
    currentSupply = ""): PowerStatus =
  ## Read independent kernel gauges, retaining failures for the information view.
  result.selected = selected
  result.currentSupply = currentSupply
  var paths: seq[string]
  for path in walkDirs(root / "*"): paths.add path
  paths.sort()
  for path in paths:
    try:
      if readValue(path / "type") != "Battery":
        if readValue(path / "online") == "1": result.external = true
        continue
      var reading = BatteryReading(name: path.extractFilename(), percent: -1,
        status: readValue(path / "status"))
      let capacity = readValue(path / "capacity")
      if capacity.len > 0:
        try:
          let percent = parseInt(capacity)
          if percent notin 0 .. 100:
            raise newException(ValueError, "Capacity is outside 0..100")
          reading.percent = percent
        except ValueError as error:
          reading.error = error.msg
      try:
        let current = readValue(path / "current_now")
        if current.len > 0:
          reading.currentMicroamps = some(parseInt(current))
      except ValueError, IOError, OSError:
        if reading.error.len > 0: reading.error &= "; "
        reading.error &= "Current unavailable: " & getCurrentExceptionMsg()
      result.batteries.add reading
    except IOError, OSError:
      result.batteries.add BatteryReading(name: path.extractFilename(),
        percent: -1, error: getCurrentExceptionMsg())
  if result.selected.len == 0 and result.batteries.len > 0:
    result.selected = result.batteries[0].name

proc selectedBattery*(power: PowerStatus): BatteryReading =
  ## Never substitute a different gauge for an explicitly selected battery.
  for reading in power.batteries:
    if reading.name == power.selected: return reading
  BatteryReading(name: power.selected, percent: -1)

proc batteryFlow*(power: PowerStatus): BatteryFlow =
  ## Prefer signed battery current over a driver's charger-presence status.
  let
    selected = power.selectedBattery()
    source = if power.currentSupply.len > 0: power.currentSupply else: power.selected
  for reading in power.batteries:
    if reading.name == source and reading.currentMicroamps.isSome:
      let current = reading.currentMicroamps.get()
      if current < 0: return DischargingFlow
      if current > 0: return ChargingFlow
      return if selected.status == "Full": FullFlow else: IdleFlow
  if power.currentSupply.len > 0: return UnknownFlow
  case selected.status
  of "Charging": ChargingFlow
  of "Discharging": DischargingFlow
  of "Full": FullFlow
  of "Not charging": IdleFlow
  else: UnknownFlow

proc batteryText*(power: PowerStatus): string =
  ## Show battery percentage and external-power connection independently of flow.
  let reading = power.selectedBattery()
  result = if reading.percent >= 0: $reading.percent & "%" else: "Battery —"
  if power.external: result &= " · Plugged in"
  elif reading.percent >= 0: result &= " · On battery"

proc chargeText*(power: PowerStatus): string =
  ## Describe battery flow while plugged in, including an unavailable measurement.
  if not power.external: return ""
  case power.batteryFlow()
  of ChargingFlow: "Charging"
  of DischargingFlow: "Battery draining"
  of FullFlow: "Full"
  of IdleFlow: "Not charging"
  of UnknownFlow: "Charge state unknown"

proc osName*(contents: string): string =
  ## Parse os-release as data, never as a shell script.
  for line in contents.splitLines():
    if line.startsWith("PRETTY_NAME="):
      return line[12 .. ^1].strip(chars = {'"', '\''})
  "Unknown OS"

proc localSystem*(): seq[string] =
  ## Read static host identity without contacting another machine.
  var identity: Utsname
  if uname(identity) != 0: raiseOSError(osLastError(), "uname")
  let architecture = $cast[cstring](addr identity.machine[0])
  result = @[
    "Host: " & readValue("/proc/sys/kernel/hostname"),
    "OS: " & osName(readValue("/etc/os-release")),
    "Kernel: " & readValue("/proc/sys/kernel/osrelease"),
    "Architecture: " & architecture
  ]

proc networkLines*(contents: string): seq[string] =
  ## Show Ethernet and Wi-Fi interfaces, including disconnected interfaces.
  for link in parseJson(contents):
    if link{"ifname"}.getStr() == "lo" or link{"link_type"}.getStr() != "ether":
      continue
    let
      name = link["ifname"].getStr()
      mac = link{"address"}.getStr("Unavailable")
      state = link{"operstate"}.getStr("Unknown")
    result.add name & "  " & state & "  MAC " & mac
    var addresses = 0
    for address in link["addr_info"]:
      result.add "  " & address["local"].getStr() & "/" & $address["prefixlen"].getInt()
      inc addresses
    if addresses == 0: result.add "  No IP address"
  if result.len == 0: result.add "No Ethernet or Wi-Fi interfaces"

proc localNetwork*(): seq[string] =
  ## Query the installed iproute2 utility without invoking a shell or DNS.
  try:
    let process = startProcess("ip", args = ["-j", "address", "show"],
      options = {poUsePath, poStdErrToStdOut})
    defer: process.close()
    let
      output = process.outputStream.readAll()
      code = process.waitForExit()
    if code != 0:
      raise newException(IOError, "ip exited with " & $code & ": " & output.strip())
    result = networkLines(output)
  except CatchableError as error:
    result = @["Network unavailable: " & error.msg]

proc powerLines*(power: PowerStatus): seq[string] =
  ## Show each gauge separately to make device-specific reporting visible.
  if power.external:
    result.add "Plugged in: " & power.chargeText()
    if power.batteryFlow() == DischargingFlow:
      result.add "External power is not keeping up with use."
  else:
    result.add "External power not detected"
  if power.currentSupply.len > 0:
    result.add "Battery current source: " & power.currentSupply
  if power.batteries.len == 0: result.add "No battery detected"
  for reading in power.batteries:
    let percent = if reading.percent >= 0: $reading.percent & "%" else: "Unavailable"
    result.add reading.name & " (gauge): " & percent & "  " & reading.status
    if reading.currentMicroamps.isSome:
      let milliamps = reading.currentMicroamps.get() div 1000
      result.add "  Battery current: " & $milliamps & " mA (positive = charging)"
    if reading.error.len > 0: result.add "  " & reading.error
