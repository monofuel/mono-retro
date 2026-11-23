import
  std/[json, jsonutils, monotimes, os, osproc, parseopt, posix, strutils,
    tempfiles, times],
  pixie,
  windy/platforms/linux/x11/[x, xevent, xlib],
  retro/[bluetooth, gamelibrary]

const
  DeviceAddress = "01:23:45:67:89:AB"
  DeviceName = "Bluetooth fixture headphones"
  FixturePin = "2468"
  EnterKey = 0xff0d.culong
  EscapeKey = 0xff1b.culong
  StartKey = 0xff09.culong
  UpKey = 0xff52.culong
  DownKey = 0xff54.culong

proc queryTree(d: Display, window: Window, root, parent: ptr Window,
  children: ptr ptr UncheckedArray[Window], count: ptr cuint): cint
  {.cdecl, importc: "XQueryTree", dynlib: libX11.}
proc fetchName(d: Display, window: Window, name: ptr cstring): cint
  {.cdecl, importc: "XFetchName", dynlib: libX11.}
proc keycode(d: Display, symbol: culong): cuchar
  {.cdecl, importc: "XKeysymToKeycode", dynlib: libX11.}
proc sendEvent(d: Display, window: Window, propagate: cint, mask: clong,
  event: ptr XEvent): cint {.cdecl, importc: "XSendEvent", dynlib: libX11.}
proc closeDisplay(d: Display): cint {.cdecl, importc: "XCloseDisplay", dynlib: libX11.}
proc getImage(d: Display, window: Window, x, y: cint, width, height: cuint,
  planes: culong, format: cint): pointer {.cdecl, importc: "XGetImage", dynlib: libX11.}
proc getPixel(image: pointer, x, y: cint): culong {.cdecl, importc: "XGetPixel", dynlib: libX11.}
proc destroyImage(image: pointer): cint {.cdecl, importc: "XDestroyImage", dynlib: libX11.}

proc snapshot(path: string, state: BtState) =
  ## Publish only complete private fake-worker snapshots.
  writeFile(path & ".tmp", state.stateJson())
  setFilePermissions(path & ".tmp", {fpUserRead, fpUserWrite})
  moveFile(path & ".tmp", path)
  let root = getEnv("MONO_RETRO_BT_X11_ROOT")
  if root.len > 0: writeFile(root / "last-state.json", state.stateJson())

proc setMode(root, mode: string) =
  ## Change fixture behavior atomically before sending the next UI action.
  writeFile(root / "mode.tmp", mode)
  moveFile(root / "mode.tmp", root / "mode")

proc fakeWorker() =
  ## Replace the radio worker with deterministic stdin commands and local fixtures.
  let root = getEnv("MONO_RETRO_BT_X11_ROOT")
  var
    statePath, mode = ""
    state = BtState(available: true, powered: true, devices: @[
      BtDevice(address: DeviceAddress, name: DeviceName, batteryPercent: 67)])
    input = ""
  for kind, key, value in getopt():
    if kind == cmdLongOption and key == "state": statePath = value
  doAssert statePath.len > 0 and root.len > 0
  proc applyMode() =
    ## Deliver unsolicited readiness changes without opening a real bus.
    let current = readFile(root / "mode").strip()
    if current == mode: return
    mode = current
    if mode in ["ready", "late-ready"]:
      state.devices[0].paired = true
      state.devices[0].connected = true
      state.devices[0].audioReady = true
      state.busy = false
      state.error = ""
    elif mode == "unavailable":
      state.devices[0].paired = true
      state.devices[0].connected = false
      state.devices[0].audioReady = false
      state.busy = false
    elif mode in ["pin", "passkey"]:
      state.devices[0].paired = false
      state.devices[0].connected = false
      state.devices[0].audioReady = false
    statePath.snapshot(state)
  applyMode()
  statePath.snapshot(state)
  while true:
    applyMode()
    var descriptor = TPollfd(fd: STDIN_FILENO, events: POLLIN)
    let ready = poll(addr descriptor, Tnfds(1), 20)
    if ready < 0: raiseOSError(osLastError())
    if ready == 0: continue
    var bytes: array[4096, char]
    let count = posix.read(STDIN_FILENO, addr bytes[0], bytes.len)
    if count < 0: raiseOSError(osLastError())
    if count == 0: return
    for index in 0 ..< count: input.add bytes[index]
    while '\n' in input:
      let separator = input.find('\n')
      let command = commandFromJson(input[0 ..< separator])
      input.delete(0 .. separator)
      applyMode()
      state.request = command.request
      state.error = ""
      var audit = %*{"action": command.action, "address": command.address,
        "enabled": command.enabled, "request": command.request}
      if command.action == "reply" and command.value in ["yes", "no"]:
        audit["answer"] = %command.value
      let log = open(root / "commands.jsonl", fmAppend)
      log.writeLine($audit)
      log.close()
      case command.action
      of "status": discard
      of "scan": state.discovering = command.enabled
      of "pair":
        doAssert command.address == DeviceAddress
        state.busy = true
        state.prompt = if mode == "pin":
          BtPrompt(kind: PinPrompt, address: DeviceAddress, text: "Enter fixture PIN")
        elif mode == "passkey":
          BtPrompt(kind: PasskeyPrompt, address: DeviceAddress, text: "Enter numeric fixture passkey")
        else:
          BtPrompt(kind: ConfirmPrompt, address: DeviceAddress, passkey: 246810,
            code: "246810", text: "Check the fixture code")
      of "reply":
        if state.prompt.kind in [PinPrompt, PasskeyPrompt]:
          doAssert command.value == FixturePin
          writeFile(root / (if state.prompt.kind == PinPrompt: "pin-accepted" else: "passkey-accepted"), "yes")
          state.devices[0].paired = true
          state.devices[0].connected = true
          state.devices[0].audioReady = true
        state.busy = false
        state.prompt = BtPrompt()
      of "cancel":
        state.busy = false
        state.discovering = false
        state.prompt = BtPrompt()
      of "connect":
        doAssert command.address == DeviceAddress
        if mode == "retry-fail": state.error = "Fixture connection failed"
        elif mode == "retry-hold": state.busy = true
        elif mode == "retry-ready":
          state.busy = false
          state.devices[0].paired = true
          state.devices[0].connected = true
          state.devices[0].audioReady = true
        else: raise newException(ValueError, "Unexpected fixture connect mode")
      else: raise newException(ValueError, "Unexpected fixture Bluetooth command")
      statePath.snapshot(state)

proc findWindow(display: Display, previous = Window(0)): Window =
  ## Find only launcher windows on the explicitly isolated test server.
  let deadline = getMonoTime() + initDuration(seconds = 6)
  while getMonoTime() < deadline:
    var
      root, parent: Window
      children: ptr UncheckedArray[Window]
      count: cuint
    doAssert queryTree(display, display.defaultRootWindow, addr root, addr parent,
      addr children, addr count) != 0
    try:
      for index in 0 ..< int(count):
        var name: cstring
        if fetchName(display, children[index], addr name) != 0 and name != nil:
          let matches = $name == "LINUX HANDHELD" and children[index] != previous
          XFree(name)
          if matches: return children[index]
    finally:
      if children != nil: XFree(children)
    sleep(10)
  raise newException(IOError, "Bluetooth integration launcher window did not appear")

proc press(display: Display, window: Window, symbol: culong) =
  ## Send key transitions exclusively to the test's private Xvfb server.
  for kind in [xeKeyPress, xeKeyRelease]:
    var event = XEvent(key: XKeyEvent(kind: kind, display: display, window: window,
      root: display.defaultRootWindow, keycode: keycode(display, symbol).cuint, same_screen: 1))
    doAssert sendEvent(display, window, 0, if kind == xeKeyPress: 1 else: 2, addr event) != 0
  display.XFlush()
  sleep(100)

proc capture(display: Display, window: Window, name: string) =
  ## Preserve an actual rendered X11 screenshot for native-resolution review.
  sleep(200)
  var attributes: XWindowAttributes
  XGetWindowAttributes(display, window, addr attributes)
  doAssert attributes.size.x > 0 and attributes.size.y > 0
  let
    width = attributes.size.x.int
    height = attributes.size.y.int
    pixels = getImage(display, window, 0, 0, width.cuint, height.cuint, high(culong), 2)
    image = newImage(width, height)
  doAssert pixels != nil
  defer: discard destroyImage(pixels)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let pixel = getPixel(pixels, x.cint, y.cint)
      image.data[y * width + x] = rgbx(uint8(pixel shr 16 and 255),
        uint8(pixel shr 8 and 255), uint8(pixel and 255), 255)
  image.writeFile("build/bluetooth/integration-" & name & ".png")

proc commands(root: string, action: string): seq[JsonNode] =
  ## Read the fixture command audit, which never stores entered PIN values.
  let path = root / "commands.jsonl"
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    if line.len == 0: continue
    let command = parseJson(line)
    if command["action"].getStr() == action: result.add command

template awaitFixture(condition: untyped) =
  block:
    let deadline = getMonoTime() + initDuration(seconds = 6)
    while not (condition) and getMonoTime() < deadline: sleep(20)
    doAssert condition
    sleep(250)

proc integration() =
  ## Exercise real launcher navigation, pairing dialogs and guarded app handoffs.
  let
    testDisplay = getEnv("MONO_RETRO_TEST_DISPLAY")
    root = createTempDir("mono-retro-bt-x11-", "")
    runtime = root / "runtime"
    configPath = root / "config/library.json"
    paths = libraryPaths(root, configPath)
    rom = root / "Roms/NDS/Fixture.nds"
    core = root / "fixture.so"
    player = runtime / "player"
    marker = root / "launches"
    audioPreference = root / "preferences/mono-retro/audio-output.json"
  doAssert testDisplay.len > 0, "Set MONO_RETRO_TEST_DISPLAY to a private Xvfb display."
  doAssert findExe("bwrap").len > 0, "The isolated test needs bwrap to hide host input/audio devices."
  defer:
    if fileExists(root / "commands.jsonl"):
      copyFile(root / "commands.jsonl", "build/bluetooth/integration-commands.jsonl")
    if fileExists(root / "last-state.json"):
      copyFile(root / "last-state.json", "build/bluetooth/integration-last-state.json")
    removeDir(root)
  createDir(runtime)
  createDir(root / "tmp")
  createDir(rom.parentDir)
  createDir(configPath.parentDir)
  createDir("build/bluetooth")
  writeFile("build/bluetooth/integration-result.json", $(%*{"passed": false}))
  writeFile(rom, "synthetic Bluetooth launch fixture")
  writeFile(core, "synthetic core path")
  root.setMode("confirm")
  writeFile(player, "#!/bin/sh\nprintf x >> " & quoteShell(marker) &
    "\nprintf '%s\\n' \"$@\" > " & quoteShell(root / "player-arguments") & "\n")
  setFilePermissions(player, {fpUserRead, fpUserWrite, fpUserExec})
  for binary in ["mono-retro", "mono-retro-library"]:
    copyFile(absolutePath("build" / binary), runtime / binary)
    setFilePermissions(runtime / binary, {fpUserRead, fpUserWrite, fpUserExec})
  copyFile(getAppFilename(), runtime / "mono-retro-bluetooth")
  setFilePermissions(runtime / "mono-retro-bluetooth", {fpUserRead, fpUserWrite, fpUserExec})
  let config = LibraryConfig(playerPath: player, cores: @[
    CoreConfig(key: "ds", path: core, platforms: @["nds"])])
  writeFile(configPath, $config.toJson())
  putEnv("DISPLAY", testDisplay)
  putEnv("XDG_CONFIG_HOME", root / "preferences")
  putEnv("TMPDIR", root / "tmp")
  putEnv("MONO_RETRO_BT_X11_ROOT", root)
  putEnv("ALSOFT_DRIVERS", "null")
  let
    process = startProcess(findExe("bwrap"), args = ["--die-with-parent", "--ro-bind", "/", "/",
      "--bind", root, root, "--dev", "/dev", "--tmpfs", "/sys/class/input",
      "--", runtime / "mono-retro", "--library:" & root, "--config:" & configPath,
      "--device:generic", "--theme:library", "--seconds:90"], options = {poParentStreams})
    display = XOpenDisplay(testDisplay.cstring)
  doAssert display != nil
  defer:
    discard closeDisplay(display)
    if process.running(): process.terminate()
    if process.waitForExit(5000) == -1:
      process.kill()
      discard process.waitForExit()
    process.close()
  var window = findWindow(display)
  awaitFixture(fileExists(paths.index))
  press(display, window, StartKey)
  for attempt in 0 ..< 10: press(display, window, UpKey)
  for attempt in 0 ..< 3: press(display, window, DownKey)
  press(display, window, EnterKey)
  press(display, window, DownKey)
  press(display, window, EnterKey)
  awaitFixture(root.commands("status").len > 0)
  capture(display, window, "devices")
  press(display, window, 0x78)
  awaitFixture(root.commands("scan").len == 1)
  doAssert root.commands("scan")[0]["enabled"].getBool()
  press(display, window, DownKey)
  press(display, window, EnterKey)
  capture(display, window, "device-detail")
  press(display, window, EnterKey)
  awaitFixture(root.commands("pair").len == 1)
  doAssert root.commands("pair")[0]["address"].getStr() == DeviceAddress
  capture(display, window, "confirmation-default-no")
  press(display, window, EnterKey)
  awaitFixture(root.commands("reply").len == 1)
  doAssert root.commands("reply")[0]["answer"].getStr() == "no"
  root.setMode("pin")
  sleep(300)
  press(display, window, EnterKey)
  awaitFixture(root.commands("pair").len == 2)
  capture(display, window, "pin-keyboard")
  for digit in FixturePin: press(display, window, ord(digit).culong)
  press(display, window, EnterKey)
  awaitFixture(fileExists(root / "pin-accepted"))
  press(display, window, DownKey)
  press(display, window, EnterKey)
  awaitFixture(fileExists(audioPreference))
  doAssert parseFile(audioPreference)["address"].getStr() == DeviceAddress
  capture(display, window, "audio-selected")
  root.setMode("ready")
  sleep(100)
  root.setMode("pin")
  sleep(300)
  for attempt in 0 ..< 4: press(display, window, UpKey)
  press(display, window, EnterKey)
  awaitFixture(root.commands("pair").len == 3)
  let beforeCancel = root.commands("cancel").len
  press(display, window, EscapeKey)
  awaitFixture(root.commands("cancel").len > beforeCancel)
  root.setMode("passkey")
  sleep(300)
  press(display, window, EnterKey)
  awaitFixture(root.commands("pair").len == 4)
  let repliesBeforeInvalidPasskey = root.commands("reply").len
  press(display, window, 0x61)
  press(display, window, EnterKey)
  sleep(250)
  doAssert root.commands("reply").len == repliesBeforeInvalidPasskey
  doAssert not fileExists(root / "passkey-accepted")
  capture(display, window, "invalid-passkey-stays-keyboard")
  press(display, window, 0xff08)
  for digit in FixturePin: press(display, window, ord(digit).culong)
  press(display, window, EnterKey)
  awaitFixture(fileExists(root / "passkey-accepted"))
  root.setMode("ready")
  sleep(300)
  for attempt in 0 ..< 3: press(display, window, EscapeKey)
  root.setMode("unavailable")
  sleep(400)
  press(display, window, EnterKey)
  capture(display, window, "audio-unavailable")
  let failureCancel = root.commands("cancel").len
  root.setMode("retry-fail")
  press(display, window, EnterKey)
  awaitFixture(root.commands("connect").len == 1)
  awaitFixture(root.commands("cancel").len > failureCancel)
  doAssert not fileExists(marker)
  capture(display, window, "retry-failed")
  root.setMode("retry-ready")
  press(display, window, EnterKey)
  try: awaitFixture(fileExists(marker))
  except AssertionDefect:
    capture(display, window, "failure-after-ready-retry")
    raise
  window = findWindow(display, window)
  doAssert readFile(marker) == "x"
  doAssert ("--save-dir:" & paths.data / "saves/ds" / fileHash(rom)) in readFile(root / "player-arguments")
  capture(display, window, "returned-after-launch")
  root.setMode("unavailable")
  sleep(400)
  press(display, window, EnterKey)
  root.setMode("retry-hold")
  press(display, window, EnterKey)
  awaitFixture(root.commands("connect").len == 3)
  let pendingCancel = root.commands("cancel").len
  press(display, window, StartKey)
  awaitFixture(root.commands("cancel").len > pendingCancel)
  root.setMode("late-ready")
  sleep(1000)
  doAssert readFile(marker) == "x", "Cancelled retry launched a game after a late ready snapshot"
  doAssert process.running()
  capture(display, window, "cancelled-retry-no-late-launch")
  copyFile(root / "commands.jsonl", "build/bluetooth/integration-commands.jsonl")
  press(display, window, EscapeKey)
  doAssert process.waitForExit(5000) == 0
  writeFile("build/bluetooth/integration-result.json", $(%*{"passed": true,
    "launches": 1, "scanEnabled": true, "defaultConfirmation": "no",
    "pinReply": true, "pinCancel": true, "invalidPasskeyRejectedLocally": true,
    "failedThenSuccessfulRetry": true, "cancelledRetryIgnoredLateReady": true,
    "isolatedDevices": true, "deviceAddress": DeviceAddress, "deviceName": DeviceName,
    "launcher": "build/mono-retro", "libraryHelper": "build/mono-retro-library",
    "fixture": "Synthetic NDS ROM, placeholder core, silent shell marker player"}))

when isMainModule:
  if getEnv("MONO_RETRO_BT_X11_ROOT").len > 0 and paramCount() > 0 and
      paramStr(1).startsWith("--state:"):
    fakeWorker()
  else: integration()
