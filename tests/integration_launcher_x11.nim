import
  std/[monotimes, os, osproc, times],
  windy/platforms/linux/x11/[x, xevent, xlib]

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

proc findWindow(d: Display, previous: Window): Window =
  ## Wait for the launcher to replace its window after the child exits.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    var
      root, parent: Window
      children: ptr UncheckedArray[Window]
      count: cuint
    doAssert queryTree(d, d.defaultRootWindow, addr root, addr parent, addr children, addr count) != 0
    try:
      for index in 0 ..< int(count):
        var name: cstring
        if fetchName(d, children[index], addr name) != 0 and name != nil:
          let matched = $name == "LINUX HANDHELD" and children[index] != previous
          XFree(name)
          if matched: return children[index]
    finally:
      if children != nil: XFree(children)
    sleep(10)
  raise newException(IOError, "Launcher did not create its X11 window")

proc press(d: Display, window: Window, symbol: culong) =
  ## Deliver real X11 press/release events through Windy's desktop backend.
  for kind in [xeKeyPress, xeKeyRelease]:
    var event = XEvent(key: XKeyEvent(kind: kind, display: d, window: window,
      root: d.defaultRootWindow, keycode: keycode(d, symbol).cuint, same_screen: 1))
    doAssert sendEvent(d, window, 0, if kind == xeKeyPress: 1 else: 2, addr event) != 0
  d.XFlush()
  sleep(40)

proc main() =
  ## Exercise repeated tester failures and desktop navigation on isolated Xvfb.
  let
    testDisplay = getEnv("MONO_RETRO_TEST_DISPLAY")
    fixture = getTempDir() / ("mono-retro-x11-" & $getCurrentProcessId())
    tester = fixture / "tester"
    game = fixture / "decompbound"
    marker = fixture / "launches"
    gameMarker = fixture / "games"
    powerMarker = fixture / "power-requests"
    originalPath = getEnv("PATH")
  doAssert testDisplay.len > 0, "Set MONO_RETRO_TEST_DISPLAY to an isolated Xvfb display."
  createDir(fixture)
  defer:
    putEnv("PATH", originalPath)
    removeDir(fixture)
  for command in ["reboot", "poweroff"]:
    writeFile(fixture / command, "#!/bin/sh\nprintf '" & command & "\\n' >> " & quoteShell(powerMarker) & "\n")
    setFilePermissions(fixture / command, {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", fixture & ":" & originalPath)
  doAssert findExe("reboot") == fixture / "reboot"
  doAssert findExe("poweroff") == fixture / "poweroff"
  writeFile(tester, "#!/bin/sh\nprintf x >> " & quoteShell(marker) & "\nexit 7\n")
  setFilePermissions(tester, {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(game, "#!/bin/sh\ntest \"$#\" = 0 || exit 2\nprintf x >> " & quoteShell(gameMarker) & "\n")
  setFilePermissions(game, {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("DISPLAY", testDisplay)
  let
    process = startProcess(absolutePath("build/mono-retro"),
      args = ["--device:generic", "--tester:" & tester, "--decompbound:" & game, "--seconds:20"], options = {poParentStreams})
    d = XOpenDisplay(testDisplay.cstring)
  doAssert d != nil
  defer:
    discard closeDisplay(d)
    if process.running(): process.terminate()
    discard process.waitForExit(5000)
    process.close()
  var window = findWindow(d, 0)
  for attempt in 1 .. 2:
    sleep(80)
    press(d, window, 0xff0d)
    window = findWindow(d, window)
    doAssert readFile(gameMarker).len == attempt
  press(d, window, 0xff54)
  for attempt in 1 .. 2:
    press(d, window, 0xff0d)
    window = findWindow(d, window)
    doAssert readFile(marker).len == attempt
  press(d, window, 0xff54)
  press(d, window, 0xff0d)
  doAssert process.running()
  press(d, window, 0xff1b)
  doAssert process.running()
  press(d, window, 0xff54)
  press(d, window, 0xff0d)
  press(d, window, 0xff0d)
  doAssert process.running()
  press(d, window, 0xff54)
  press(d, window, 0xff0d)
  press(d, window, 0xff1b)
  doAssert process.running()
  doAssert not fileExists(powerMarker)
  press(d, window, 0xff0d)
  press(d, window, 0xff53)
  press(d, window, 0xff0d)
  doAssert readFile(powerMarker) == "poweroff\n"
  doAssert process.running()
  process.terminate()
  doAssert process.waitForExit(5000) == 0

main()
