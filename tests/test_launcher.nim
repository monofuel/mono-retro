import
  std/[json, monotimes, os, times],
  pixie,
  retro/[launcherui, menu, settings, systeminfo, testerprocess]

block:
  var state = MenuState(armed: false)
  doAssert state.handle(Open, false) == NoAction
  state.armed = true
  doAssert state.handle(Open, false) == LaunchTester
  discard state.handle(Next, false)
  discard state.handle(Next, false)
  doAssert state.selected == 1
  doAssert state.handle(Open, false) == NoAction and state.info
  discard state.handle(Next, false)
  doAssert state.scroll == ScrollStep
  discard state.handle(Back, false)
  doAssert not state.info and state.scroll == 0
  doAssert state.handle(Back, false) == NoAction
  doAssert state.handle(Back, true) == QuitLauncher

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
  doAssert power.batteryText() == "59%  On battery"
  writeFile(fixture / "cw2015-battery/status", "Charging")
  doAssert readPower("cw2015-battery", fixture).batteryText() == "59%  Charging"
  writeFile(fixture / "cw2015-battery/status", "Full")
  doAssert readPower("cw2015-battery", fixture).batteryText() == "59%  Full"
  writeFile(fixture / "cw2015-battery/capacity", "999")
  power = readPower("cw2015-battery", fixture)
  doAssert power.selectedBattery().percent == -1
  doAssert power.selectedBattery().error.len > 0
  doAssert readPower("missing", fixture).selectedBattery().percent == -1
  doAssert readPower("", fixture / "missing").batteries.len == 0
  doAssert parseSettings(@[], rgSpDevice).batterySupply == "axp2202-battery"
  doAssert parseSettings(@[], rgDsPlusDevice).batterySupply == "cw2015-battery"

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
