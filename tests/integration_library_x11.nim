import
  std/[json, jsonutils, monotimes, os, osproc, strutils, tempfiles, times],
  windy/platforms/linux/x11/[x, xevent, xlib],
  retro/gamelibrary

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

proc findWindow(display: Display, previous: Window): Window =
  ## Wait for a fresh library window after each child process releases the screen.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    var
      root, parent: Window
      children: ptr UncheckedArray[Window]
      count: cuint
    doAssert queryTree(display, display.defaultRootWindow, addr root, addr parent, addr children, addr count) != 0
    try:
      for index in 0 ..< int(count):
        var name: cstring
        if fetchName(display, children[index], addr name) != 0 and name != nil:
          let matched = $name == "LINUX HANDHELD" and children[index] != previous
          XFree(name)
          if matched: return children[index]
    finally:
      if children != nil: XFree(children)
    sleep(10)
  raise newException(IOError, "Library window did not appear")

proc press(display: Display, window: Window, symbol: culong) =
  ## Deliver keyboard transitions to the isolated X11 server only.
  for kind in [xeKeyPress, xeKeyRelease]:
    var event = XEvent(key: XKeyEvent(kind: kind, display: display, window: window,
      root: display.defaultRootWindow, keycode: keycode(display, symbol).cuint, same_screen: 1))
    doAssert sendEvent(display, window, 0, if kind == xeKeyPress: 1 else: 2, addr event) != 0
  display.XFlush()
  sleep(80)

proc main() =
  ## Exercise library discovery, card-backed launch arguments and repeated returns.
  let
    testDisplay = getEnv("MONO_RETRO_TEST_DISPLAY")
    root = createTempDir("mono-retro-library-x11-", "")
    configPath = root / "config" / "library.json"
    paths = libraryPaths(root, configPath)
    marker = root / "player-arguments"
    player = root / "player"
    core = root / "fixture.so"
    rom = root / "Roms/NDS/Fixture.nds"
  doAssert testDisplay.len > 0
  defer: removeDir(root)
  createDir(rom.parentDir)
  createDir(configPath.parentDir)
  writeFile(rom, "synthetic DS fixture")
  writeFile(core, "fixture")
  writeFile(player, "#!/bin/sh\nprintf '%s\\n' \"$@\" > " & quoteShell(marker) & "\n")
  setFilePermissions(player, {fpUserRead, fpUserWrite, fpUserExec})
  let config = LibraryConfig(playerPath: player, cores: @[
    CoreConfig(key: "ds", path: core, platforms: @["nds"])])
  writeFile(configPath, $config.toJson())
  putEnv("DISPLAY", testDisplay)
  let
    process = startProcess(absolutePath("build/mono-retro"), args = @[
      "--library:" & root, "--config:" & configPath, "--device:generic", "--seconds:25"], options = {poParentStreams})
    display = XOpenDisplay(testDisplay.cstring)
  doAssert display != nil
  defer:
    discard closeDisplay(display)
    if process.running(): process.terminate()
    discard process.waitForExit(5000)
    process.close()
  var window = findWindow(display, 0)
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not fileExists(paths.index) and getMonoTime() < deadline: sleep(10)
  doAssert fileExists(paths.index)
  sleep(200)
  for attempt in 0 .. 1:
    press(display, window, 0xff0d)
    window = findWindow(display, window)
    doAssert fileExists(marker)
    let arguments = readFile(marker)
    doAssert ("--save-dir:" & paths.data / "saves/ds" / fileHash(rom)) in arguments
    doAssert ("--screenstate-dir:" & paths.data / "screenshots") in arguments
    sleep(100)
  press(display, window, 0x79)
  sleep(250)
  doAssert paths.loadIndex().games[0].favourite
  press(display, window, 0x78)
  press(display, window, 0xff1b)
  doAssert process.running()
  press(display, window, 0xff09)
  press(display, window, 0xff54)
  press(display, window, 0xff0d)
  press(display, window, 0xff1b)
  press(display, window, 0xff1b)
  doAssert process.waitForExit(5000) == 0

main()
