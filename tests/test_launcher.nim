import
  std/[json, monotimes, options, os, osproc, strutils, times],
  pixie,
  retro/[launcherui, menu, powercontrol, settings, systeminfo, testerprocess]

block:
  var state = MenuState(armed: false)
  doAssert state.handle(Open, false) == NoAction
  state.armed = true
  doAssert MenuLabels[0] == "Decompbound"
  doAssert state.handle(Open, false) == LaunchDecompbound
  discard state.handle(Next, false)
  doAssert state.selected == 1
  doAssert state.handle(Open, false) == LaunchTester
  discard state.handle(Next, false)
  doAssert state.handle(Open, false) == NoAction and state.info
  discard state.handle(Next, false)
  doAssert state.scroll == ScrollStep
  discard state.handle(Back, false)
  doAssert not state.info and state.scroll == 0
  doAssert state.handle(Back, false) == NoAction
  doAssert state.handle(Back, true) == QuitLauncher
  state.selected = 0
  doAssert state.handle(Open, false) == LaunchDecompbound

block:
  var state = MenuState(armed: true, lostInBlue: true)
  doAssert state.labels() == @["Decompbound", "Lost in Blue", "Hardware Test",
    "System Info", "Reboot", "Shut Down"]
  doAssert state.handle(Open, false) == LaunchDecompbound
  discard state.handle(Next, false)
  doAssert state.handle(Open, false) == LaunchLostInBlue
  discard state.handle(Next, false)
  doAssert state.handle(Open, false) == LaunchTester
  discard state.handle(Next, false)
  doAssert state.handle(Open, false) == NoAction and state.info
  discard state.handle(Back, false)
  discard state.handle(Next, false)
  discard state.handle(Open, false)
  doAssert state.confirmation == RebootSystem
  discard state.handle(Back, false)
  discard state.handle(Next, false)
  state.armed = true
  discard state.handle(Open, false)
  doAssert state.confirmation == ShutdownSystem

block:
  for (index, action) in [(3, RebootSystem), (4, ShutdownSystem)]:
    var state = MenuState(selected: index, armed: true)
    doAssert state.handle(Open, false) == NoAction
    doAssert state.confirmation == action and not state.confirmYes
    doAssert not state.armed
    discard state.handle(Next, false)
    doAssert state.handle(Open, false) == NoAction
    state.armed = true
    discard state.handle(Previous, false)
    doAssert state.handle(Open, false) == NoAction
    doAssert state.confirmation == NoAction
    discard state.handle(Open, false)
    doAssert state.handle(Back, true) == NoAction
    doAssert state.confirmation == NoAction
    state.armed = true
    discard state.handle(Open, false)
    discard state.handle(Next, false)
    state.armed = true
    doAssert state.handle(Open, false) == action
    state.busy = true
    doAssert state.handle(Back, true) == NoAction
  doAssert powerBlockReason(PowerStatus(selected: "axp2202-battery", external: true)).len > 0
  doAssert powerBlockReason(PowerStatus(selected: "axp2202-battery")).len == 0
  doAssert powerBlockReason(PowerStatus(selected: "cw2015-battery", external: true)).len == 0

block:
  let
    fixture = getTempDir() / ("mono-retro-power-commands-" & $getCurrentProcessId())
    originalPath = getEnv("PATH")
    marker = fixture / "requests"
  createDir(fixture)
  defer:
    putEnv("PATH", originalPath)
    removeDir(fixture)
  for command in ["reboot", "poweroff"]:
    writeFile(fixture / command, "#!/bin/sh\nprintf '" & command & "\\n' >> '" & marker & "'\n")
    setFilePermissions(fixture / command, {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", fixture)
  doAssert findExe("reboot") == fixture / "reboot"
  doAssert findExe("poweroff") == fixture / "poweroff"
  for action in [RebootSystem, ShutdownSystem]:
    var request = requestPower(action)
    discard request.waitForExit()
    checkPowerRequest(request, action)
    doAssert request == nil
  doAssert readFile(marker) == "reboot\npoweroff\n"
  writeFile(fixture / "poweroff", "#!/bin/sh\nexit 3\n")
  var rejected = false
  var request = requestPower(ShutdownSystem)
  discard request.waitForExit()
  try: checkPowerRequest(request, ShutdownSystem)
  except IOError: rejected = true
  doAssert rejected

block:
  let fixture = getTempDir() / ("mono-retro-power-" & $getCurrentProcessId())
  createDir(fixture)
  defer: removeDir(fixture)
  for (name, percent) in [("battery", "40"), ("cw2015-battery", "59")]:
    createDir(fixture / name)
    writeFile(fixture / name / "type", "Battery\n")
    writeFile(fixture / name / "status", "Discharging\n")
    writeFile(fixture / name / "capacity", percent)
  createDir(fixture / "usb")
  writeFile(fixture / "usb/type", "USB\n")
  writeFile(fixture / "usb/online", "1\n")
  var power = readPower("cw2015-battery", fixture)
  doAssert power.external and power.batteries.len == 2
  doAssert power.selectedBattery().percent == 59
  doAssert power.batteryText() == "59% · Plugged in"
  doAssert power.chargeText() == "Battery draining"
  writeFile(fixture / "cw2015-battery/status", "Charging")
  doAssert readPower("cw2015-battery", fixture).chargeText() == "Charging"
  writeFile(fixture / "cw2015-battery/status", "Full")
  doAssert readPower("cw2015-battery", fixture).chargeText() == "Full"
  writeFile(fixture / "cw2015-battery/status", "Charging")
  writeFile(fixture / "battery/status", "Charging")
  writeFile(fixture / "cw2015-battery/current_now", "0")
  writeFile(fixture / "battery/current_now", "-195000")
  power = readPower("cw2015-battery", fixture, "battery")
  doAssert power.selectedBattery().percent == 59
  doAssert power.selectedBattery().currentMicroamps == some(0)
  doAssert power.batteryFlow() == DischargingFlow
  doAssert power.chargeText() == "Battery draining"
  doAssert "External power is not keeping up with use." in power.powerLines()
  doAssert power.powerLines().join("\n").contains("-195 mA")
  writeFile(fixture / "cw2015-battery/status", "Discharging")
  writeFile(fixture / "battery/current_now", "350000")
  doAssert readPower("cw2015-battery", fixture, "battery").chargeText() == "Charging"
  writeFile(fixture / "battery/current_now", "0")
  doAssert readPower("cw2015-battery", fixture, "battery").chargeText() == "Not charging"
  writeFile(fixture / "cw2015-battery/status", "Full")
  doAssert readPower("cw2015-battery", fixture, "battery").chargeText() == "Full"
  writeFile(fixture / "battery/current_now", "not a number")
  power = readPower("cw2015-battery", fixture, "battery")
  doAssert power.chargeText() == "Charge state unknown"
  doAssert power.batteries[0].percent == 40
  doAssert power.batteries[0].error.len > 0
  removeFile(fixture / "battery/current_now")
  doAssert readPower("cw2015-battery", fixture, "battery").chargeText() == "Charge state unknown"
  doAssert readPower("cw2015-battery", fixture, "missing").chargeText() == "Charge state unknown"
  writeFile(fixture / "battery/current_now", "-195000")
  writeFile(fixture / "usb/online", "0")
  power = readPower("cw2015-battery", fixture, "battery")
  doAssert power.batteryText() == "59% · On battery"
  doAssert power.chargeText() == ""
  writeFile(fixture / "cw2015-battery/capacity", "999")
  power = readPower("cw2015-battery", fixture)
  doAssert power.selectedBattery().percent == -1
  doAssert power.selectedBattery().error.len > 0
  doAssert readPower("missing", fixture).selectedBattery().percent == -1
  doAssert readPower("", fixture / "missing").batteries.len == 0
  doAssert parseSettings(@[], rgSpDevice).batterySupply == "axp2202-battery"
  doAssert parseSettings(@[], rgDsPlusDevice).batterySupply == "cw2015-battery"
  doAssert parseSettings(@[], rgSpDevice).batteryCurrentSupply == ""
  doAssert parseSettings(@[], rgDsPlusDevice).batteryCurrentSupply == "battery"

block:
  doAssert osName("NAME=Linux\nPRETTY_NAME=\"Gentoo Linux\"\n") == "Gentoo Linux"
  let links = %*[
    {"ifname": "lo", "link_type": "loopback", "addr_info": []},
    {"ifname": "wlan0", "link_type": "ether", "address": "00:11:22:33:44:55",
      "operstate": "UP", "addr_info": [{"local": "10.1.2.3", "prefixlen": 24}]},
    {"ifname": "eth0", "link_type": "ether", "address": "00:11:22:33:44:66",
      "operstate": "DOWN", "addr_info": []}
  ]
  let lines = networkLines($links)
  doAssert lines.len == 4
  doAssert lines[1] == "  10.1.2.3/24"
  doAssert lines[3] == "  No IP address"

block:
  let ui = newLauncherUi()
  for role in ScreenRole:
    let
      width = if role == SingleScreen: 720 else: 1024
      height = if role == SingleScreen: 480 else: 768
      areas = layout(width, height, role)
      rendered = ui.render(MenuState(), "RG SP", PowerStatus(), @[], width, height, role)
    doAssert rendered.image.width == width and rendered.image.height == height
    doAssert areas.action.contains(vec2(areas.action.x.float32 + 1, areas.action.y.float32 + 1))
    doAssert areas.action.y + areas.action.height <= height
    doAssert areas.rows[^1].y + areas.rows[^1].height < areas.action.y
    doAssert not areas.cancel.contains(vec2(areas.confirm.x.float32 + 1, areas.confirm.y.float32 + 1))
    doAssert ui.render(MenuState(confirmation: ShutdownSystem), "Test", PowerStatus(),
      @[], width, height, role).image.height == height
    if role != BottomScreen:
      let
        power = PowerStatus(selected: "battery", external: true,
          batteries: @[BatteryReading(name: "battery", percent: 60,
            status: "Charging", currentMicroamps: some(-195000))])
        draining = ui.render(MenuState(), "Test", power, @[], width, height, role)
        iconX = max(width div 2, width - 315) + 3
      doAssert draining.image[iconX, 28] == rgbx(255, 205, 125, 255)
    let
      dsMenu = MenuState(lostInBlue: true, selected: 1)
      dsAreas = layout(width, height, role, dsMenu.labels().len)
    doAssert dsAreas.rows.len == 6
    doAssert dsAreas.rows[^1].y + dsAreas.rows[^1].height < dsAreas.action.y
    doAssert ui.render(dsMenu, "Test", PowerStatus(), @[], width, height, role).image.height == height
  var lines: seq[string]
  for index in 0 ..< 100: lines.add "Long information page " & $index
  doAssert ui.render(MenuState(info: true), "Test", PowerStatus(), lines,
    720, 480, SingleScreen).maxScroll > 0

block:
  let
    path = getTempDir() / ("mono-retro-child-" & $getCurrentProcessId())
    started = getMonoTime()
  writeFile(path, "#!/bin/sh\nexit 7\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  defer: removeFile(path)
  doAssert runTester(path, @[], proc(): bool = false) == 7
  writeFile(path, "#!/bin/sh\nexec sleep 20\n")
  doAssert runTester(path, @[], proc(): bool = true) != 0
  doAssert (getMonoTime() - started).inSeconds < 5
