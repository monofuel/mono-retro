import
  std/[json, jsonutils, monotimes, os, osproc, streams, strutils, tempfiles, times],
  vmath,
  windy/platforms/linux/x11/[x, xevent, xlib],
  retro/[gamelibrary, menuthemes, systeminfo]

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

proc findWindow(display: Display, previous: Window = 0): Window =
  ## Find only the menu on this test's private X server.
  let deadline = getMonoTime() + initDuration(seconds = 10)
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
  raise newException(IOError, "Private menu window did not appear")

proc press(display: Display, window: Window, symbol: culong) =
  ## Send a complete key transition to the owned isolated display.
  for kind in [xeKeyPress, xeKeyRelease]:
    var event = XEvent(key: XKeyEvent(kind: kind, display: display, window: window,
      root: display.defaultRootWindow, keycode: keycode(display, symbol).cuint, same_screen: 1))
    doAssert sendEvent(display, window, 0, if kind == xeKeyPress: 1 else: 2, addr event) != 0
  display.XFlush()
  sleep(80)

proc click(display: Display, window: Window, position: IVec2) =
  ## Click through the real mouse event path without using the human display.
  var motion = XEvent(motion: XMotionEvent(kind: xeMotion, display: display,
    window: window, root: display.defaultRootWindow, pos: position, same_screen: 1))
  doAssert sendEvent(display, window, 0, 64, addr motion) != 0
  display.XFlush()
  sleep(80)
  for kind in [xeButtonPress, xeButtonRelease]:
    var event = XEvent(button: XButtonEvent(kind: kind, display: display, window: window,
      root: display.defaultRootWindow, pos: position, button: 1, same_screen: 1))
    doAssert sendEvent(display, window, 0, if kind == xeButtonPress: 4 else: 8, addr event) != 0
    display.XFlush()
    sleep(100)

proc waitFile(path: string) =
  ## Wait for a fixture marker with a bounded deadline.
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while not fileExists(path) and getMonoTime() < deadline: sleep(10)
  doAssert fileExists(path), path

proc main() =
  ## Verify desktop game selection/launch and pairing-link activation with silent fixtures.
  let
    root = createTempDir("mono-retro-desktop-link-", "")
    bin = root / "bin"
    library = root / "library"
    configPath = root / "config.json"
    marker = root / "opened"
    played = root / "played"
    launches = root / "launches"
    ready = root / "pair-ready"
    link = "https://romm.example/pair/device?code=PUBLIC-TEST&redirect=%2Flibrary"
    server = startProcess(findExe("Xvfb"), args = ["-displayfd", "1", "-screen", "0",
      "1280x720x24", "+extension", "GLX", "-nolisten", "tcp"], options = {})
  defer:
    if server.running(): server.terminate()
    discard server.waitForExit(5000)
    server.close()
    removeDir(root)
  let number = server.outputStream.readLine().strip()
  doAssert number.len > 0 and number.allCharsInSet({'0' .. '9'})
  let testDisplay = ":" & number
  createDir(bin)
  createDir(library)
  createDir(root / "tmp")
  copyFile(absolutePath("build/mono-retro"), bin / "mono-retro")
  createDir(library / "Roms/N64")
  writeFile(library / "Roms/N64/Alpha.z64", "synthetic first game")
  writeFile(library / "Roms/N64/Beta.z64", "synthetic second game")
  writeFile(root / "core.so", "synthetic core")
  writeFile(bin / "player", "#!/bin/sh\nprintf '%s\\n' \"$@\" > " & quoteShell(played) &
    "\nprintf x >> " & quoteShell(launches) & "\n")
  writeFile(configPath, $LibraryConfig(playerPath: bin / "player", rommUrl: "https://romm.example",
    cores: @[CoreConfig(key: "fixture", path: root / "core.so", platforms: @["n64"]) ]).toJson())
  writeFile(bin / "mono-retro-library", "#!/bin/sh\nif [ \"$1\" = pair ]; then\n" &
    "for arg do case \"$arg\" in --progress:*) progress=${arg#--progress:} ;; esac; done\n" &
    "printf '%s' " & quoteShell($(%*{"message": link})) & " > \"$progress\"\n" &
    ": > " & quoteShell(ready) & "\nwhile :; do sleep 1; done\nelse\nexec " &
    quoteShell(absolutePath("build/mono-retro-library")) & " \"$@\"\nfi\n")
  writeFile(bin / "xdg-open", "#!/bin/sh\ntest \"$#\" -eq 1 || exit 7\nprintf '%s' \"$1\" > " & quoteShell(marker) & "\n")
  for file in [bin / "mono-retro", bin / "mono-retro-library", bin / "xdg-open", bin / "player"]:
    setFilePermissions(file, {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("DISPLAY", testDisplay)
  delEnv("WAYLAND_DISPLAY")
  putEnv("ALSOFT_DRIVERS", "null")
  putEnv("LIBGL_ALWAYS_SOFTWARE", "1")
  putEnv("DBUS_SYSTEM_BUS_ADDRESS", "unix:path=" & root / "no-system-bus")
  putEnv("DBUS_SESSION_BUS_ADDRESS", "unix:path=" & root / "no-session-bus")
  putEnv("XDG_CONFIG_HOME", root / "preferences")
  putEnv("TMPDIR", root / "tmp")
  putEnv("PATH", bin & ":" & getEnv("PATH"))
  let
    display = XOpenDisplay(testDisplay.cstring)
    process = startProcess(findExe("bwrap"), args = ["--die-with-parent", "--ro-bind", "/", "/",
      "--bind", root, root, "--dev", "/dev", "--tmpfs", "/sys/class/input",
      "--", bin / "mono-retro", "--library:" & library,
      "--config:" & configPath, "--device:generic", "--theme:library", "--seconds:70"],
      options = {poParentStreams})
  doAssert display != nil
  defer:
    if process.running(): process.terminate()
    discard process.waitForExit(5000)
    process.close()
    discard closeDisplay(display)
  var window = findWindow(display)
  waitFile(libraryPaths(library, configPath).index)
  sleep(500)
  var attributes: XWindowAttributes
  display.XGetWindowAttributes(window, addr attributes)
  let cards = themeLayout(LibraryTheme, attributes.size.x, attributes.size.y, 0, 2).cards
  let first = ivec2((cards[0].x + 20).int32, (cards[0].y + 20).int32)
  let second = ivec2((cards[1].x + 20).int32, (cards[1].y + 20).int32)
  click(display, window, second)
  sleep(80)
  doAssert not fileExists(played), "Single click must highlight without launching"
  press(display, window, 0xff0d)
  window = findWindow(display, window)
  waitFile(played)
  doAssert "Beta.z64" in readFile(played), "Enter must launch the clicked game"
  doAssert readFile(launches) == "x"
  removeFile(played)
  sleep(200)
  click(display, window, second)
  doAssert not fileExists(played), "First click after returning must not launch"
  click(display, window, second)
  window = findWindow(display, window)
  waitFile(played)
  doAssert "Beta.z64" in readFile(played)
  doAssert readFile(launches) == "xx", "Double-click must launch once"
  removeFile(played)
  sleep(200)
  click(display, window, second)
  sleep(500)
  click(display, window, second)
  doAssert not fileExists(played), "Separated clicks must not launch"
  click(display, window, first)
  click(display, window, second)
  doAssert not fileExists(played), "Clicks on different games must not launch"
  press(display, window, 0xff09)
  for attempt in 0 ..< 10: press(display, window, 0xff52)
  for attempt in 0 ..< 5: press(display, window, 0xff54)
  press(display, window, 0xff0d)
  waitFile(ready)
  sleep(250)
  doAssert not fileExists(marker), "Pairing must not automatically open the browser"
  click(display, window, ivec2(45, 150))
  waitFile(marker)
  doAssert readFile(marker) == link
  removeFile(marker)
  press(display, window, 0xff0d)
  waitFile(marker)
  doAssert readFile(marker) == link
  press(display, window, 0xff1b)
  doAssert process.running()

when isMainModule:
  if "--host-power" in commandLineParams():
    let power = readPower("")
    doAssert power.batteries.len == 1 and power.selectedBattery().ups
  else:
    main()
