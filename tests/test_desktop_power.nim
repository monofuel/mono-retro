import
  std/[json, os, osproc, tempfiles],
  retro/[browser, systeminfo]

proc displayDevice(kind = 3, state = 4, percent = 100.0,
    present = true, supply = true): string =
  ## Build a typed UPower reply without contacting the host power service.
  $(%*{"type": "a{sv}", "data": [{
    "Type": {"type": "u", "data": kind},
    "State": {"type": "u", "data": state},
    "Percentage": {"type": "d", "data": percent},
    "IsPresent": {"type": "b", "data": present},
    "PowerSupply": {"type": "b", "data": supply}}]})

proc main() =
  ## Cover absent/peripheral power, UPS transitions and direct browser argv handling.
  let full = upowerStatus(displayDevice())
  doAssert full.batteries.len == 1 and full.selectedBattery().ups
  doAssert full.external and full.batteryFlow() == FullFlow
  doAssert full.batteryText() == "UPS 100% · Plugged in"
  doAssert full.chargeText() == "Full"
  let draining = upowerStatus(displayDevice(state = 2, percent = 72.8))
  doAssert not draining.external and draining.selectedBattery().percent == 72
  doAssert draining.batteryFlow() == DischargingFlow
  doAssert draining.batteryText() == "UPS 72% · On battery"
  doAssert upowerStatus(displayDevice(present = false)).batteries.len == 0
  doAssert upowerStatus(displayDevice(kind = 5)).batteries.len == 0
  doAssert upowerStatus(displayDevice(supply = false)).batteries.len == 1
  doAssert upowerStatus(displayDevice(percent = 101)).selectedBattery().percent == -1
  doAssert upowerStatus(displayDevice(state = 0)).batteryText() == "UPS 100%"
  doAssert upowerStatus(displayDevice(state = 6)).batteryText() == "UPS 100%"
  let battery = upowerStatus(displayDevice(kind = 2, state = 1, percent = 53.0))
  doAssert not battery.selectedBattery().ups and battery.chargeText() == "Charging"
  let fixture = createTempDir("mono-retro-no-battery-", "")
  defer: removeDir(fixture)
  doAssert readPower("", fixture).batteries.len == 0
  let origin = "https://romm.example"
  let link = origin & "/pair/device?code=TEST-CODE&next=%2Flibrary"
  doAssert isPairingLink(link, origin)
  doAssert isPairingLink(link, origin & "/")
  for invalid in ["", "file:///tmp/private", "javascript:alert(1)", "--help",
      origin & ".evil.example/pair", origin & "@evil.example/pair", link & "\n"]:
    doAssert not isPairingLink(invalid, origin)
  let originalPath = getEnv("PATH")
  defer: putEnv("PATH", originalPath)
  let marker = fixture / "opened"
  writeFile(fixture / "xdg-open", "#!/bin/sh\ntest \"$#\" -eq 1 || exit 7\nprintf '%s' \"$1\" > \"$MONO_RETRO_TEST_LINK\"\n")
  setFilePermissions(fixture / "xdg-open", {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", fixture)
  doAssert desktopPower().batteries.len == 0
  writeFile(fixture / "busctl", "#!/bin/sh\nprintf '%s' " & quoteShell(displayDevice()) & "\n")
  setFilePermissions(fixture / "busctl", {fpUserRead, fpUserWrite, fpUserExec})
  doAssert desktopPower().batteryText() == "UPS 100% · Plugged in"
  writeFile(fixture / "busctl", "#!/bin/sh\nprintf invalid\n")
  doAssert desktopPower().batteries.len == 0
  putEnv("MONO_RETRO_TEST_LINK", marker)
  defer: delEnv("MONO_RETRO_TEST_LINK")
  let process = openPairingLink(link, origin)
  doAssert process.waitForExit() == 0
  process.close()
  doAssert readFile(marker) == link

when isMainModule:
  main()
