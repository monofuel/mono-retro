import
  std/[algorithm, json, os, osproc, posix, streams, strutils]

type
  BatteryReading* = object
    name*, status*, error*: string
    percent*: int
  PowerStatus* = object
    batteries*: seq[BatteryReading]
    selected*: string
    external*: bool

proc readValue(path: string): string =
  ## Read an optional OS attribute without inventing a value.
  if fileExists(path): readFile(path).strip() else: ""

proc readPower*(selected: string, root = "/sys/class/power_supply"): PowerStatus =
  ## Read independent kernel gauges, retaining failures for the information view.
  result.selected = selected
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

proc batteryText*(power: PowerStatus): string =
  ## Distinguish charging from merely having external power connected.
  let reading = power.selectedBattery()
  result = if reading.percent >= 0: $reading.percent & "%" else: "Battery —"
  case reading.status
  of "Charging": result &= "  Charging"
  of "Full": result &= "  Full"
  of "Discharging": result &= "  On battery"
  of "Not charging": result &= "  Not charging"
  else:
    result &= (if power.external: "  External power" else: "  Unknown")

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
  if power.batteries.len == 0: result.add "No battery detected"
  for reading in power.batteries:
    let percent = if reading.percent >= 0: $reading.percent & "%" else: "Unavailable"
    result.add reading.name & " (gauge): " & percent & "  " & reading.status
    if reading.error.len > 0: result.add "  " & reading.error
