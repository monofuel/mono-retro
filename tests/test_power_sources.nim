import
  std/[os, tempfiles],
  retro/systeminfo

proc supply(root, name, kind, scope, capacity: string, present = "1") =
  ## Create only owned synthetic power-supply attributes.
  let path = root / name
  createDir(path)
  writeFile(path / "type", kind)
  if scope.len > 0: writeFile(path / "scope", scope)
  writeFile(path / "present", present)
  writeFile(path / "capacity", capacity)
  writeFile(path / "status", "Discharging")

proc main() =
  ## Keep peripheral batteries out of automatic and profile-owned system telemetry.
  let root = createTempDir("mono-retro-power-sources-", "")
  defer: removeDir(root)
  for reverse in [false, true]:
    let fixture = root / $reverse
    createDir(fixture)
    if not reverse:
      supply(fixture, "a-controller", "Battery", "Device", "5")
      supply(fixture, "z-ups", "UPS", "System", "87")
    else:
      supply(fixture, "z-ups", "UPS", "System", "87")
      supply(fixture, "a-controller", "Battery", "Device", "5")
    var power = readPower("", fixture)
    doAssert power.batteries.len == 1 and power.selected == "z-ups"
    doAssert power.selectedBattery().ups and power.selectedBattery().percent == 87
    supply(fixture, "b-system-battery", "Battery", "System", "41")
    supply(fixture, "c-ups", "UPS", "", "64")
    power = readPower("", fixture)
    doAssert power.selected == "c-ups" and power.selectedBattery().percent == 64
    # Unplugging a controller cannot change system selection.
    removeDir(fixture / "a-controller")
    doAssert readPower("", fixture) == power
    writeFile(fixture / "c-ups/capacity", "unknown")
    power = readPower("", fixture)
    doAssert power.selected == "c-ups" and power.selectedBattery().percent == -1
    doAssert power.selectedBattery().error.len > 0
    writeFile(fixture / "c-ups/capacity", "101")
    doAssert readPower("", fixture).selectedBattery().percent == -1
    writeFile(fixture / "c-ups/present", "0")
    doAssert readPower("", fixture).selected == "z-ups"
  let desktop = root / "no-ups"
  createDir(desktop)
  supply(desktop, "controller", "Battery", "Device", "5")
  supply(desktop, "unknown-scope", "Battery", "", "95")
  doAssert readPower("", desktop).batteries.len == 0
  doAssert readPower("controller", desktop).selectedBattery().percent == -1
  supply(desktop, "z-laptop", "Battery", "System", "73")
  supply(desktop, "a-laptop", "Battery", "System", "62")
  doAssert readPower("", desktop).selected == "a-laptop"
  let handheld = root / "handheld"
  createDir(handheld)
  supply(handheld, "a-controller", "Battery", "Device", "5")
  for name in ["axp2202-battery", "cw2015-battery", "battery"]:
    supply(handheld, name, "Battery", "", "59")
    let power = readPower(name, handheld)
    doAssert power.selected == name and power.selectedBattery().percent == 59
    doAssert not power.selectedBattery().ups
    for reading in power.batteries: doAssert reading.name != "a-controller"
  doAssert readPower("missing-gauge", handheld).selectedBattery().percent == -1

main()
