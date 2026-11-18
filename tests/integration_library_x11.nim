import
  std/[json, jsonutils, monotimes, os, osproc, strutils, tempfiles, times],
  windy/platforms/linux/x11/[x, xevent, xlib],
  retro/[gamelibrary, menuthemes]

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
  putEnv("XDG_CONFIG_HOME", root / "preferences")
  let
    process = startProcess(absolutePath("build/mono-retro"), args = @[
      "--library:" & root, "--config:" & configPath, "--seconds:40"], options = {poParentStreams})
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
  let preferences = themePreferencesPath()
  for theme in [ShowcaseTheme, PocketTheme, WorkbenchTheme, LibraryTheme]:
    press(display, window, 0xff09)
    for attempt in 0 ..< 10: press(display, window, 0xff52)
    for attempt in 0 ..< 2: press(display, window, 0xff54)
    press(display, window, 0xff0d)
    press(display, window, 0xff53)
    doAssert loadTheme(preferences) != theme
    press(display, window, 0xff0d)
    doAssert loadTheme(preferences) == theme
    if theme == WorkbenchTheme:
      press(display, window, 0xff54)
      press(display, window, 0xff0d)
    press(display, window, 0xff0d)
    window = findWindow(display, window)
    doAssert fileExists(marker)
    sleep(100)
  press(display, window, 0xff09)
  press(display, window, 0xff0d)
  press(display, window, 0xff53)
  press(display, window, 0xff1b)
  doAssert loadTheme(preferences) == LibraryTheme
  press(display, window, 0xff1b)
  press(display, window, 0xff1b)
  doAssert process.waitForExit(5000) == 0

  # Simulate Wi-Fi becoming available after the first startup probe fails.
  let
    runtime = root / "runtime"
    probeCount = root / "probe-count"
    synced = root / "startup-synced"
    worker = runtime / "mono-retro-library"
  createDir(runtime)
  createDir(paths.credentials.parentDir)
  writeFile(paths.credentials, "synthetic presence marker; never a real token")
  copyFile(absolutePath("build/mono-retro"), runtime / "mono-retro")
  setFilePermissions(runtime / "mono-retro", {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(worker, "#!/bin/sh\nset -eu\n" &
    "progress=''\nfor arg in \"$@\"; do case \"$arg\" in --progress:*) progress=${arg#--progress:};; esac; done\n" &
    "case \"$1\" in\nscan) exec " & quoteShell(absolutePath("build/mono-retro-library")) & " \"$@\";;\n" &
    "probe)\n count=0\n test ! -f " & quoteShell(probeCount) & " || count=$(cat " & quoteShell(probeCount) & ")\n" &
    " count=$((count + 1))\n echo \"$count\" > " & quoteShell(probeCount) & "\n" &
    " if test \"$count\" -eq 1; then\n" &
    " printf '%s' '{\"message\":\"Cannot reach RomM\",\"error\":true}' > \"$progress.tmp\"\n" &
    " mv \"$progress.tmp\" \"$progress\"\n exit 1\n fi;;\n" &
    "sync) touch " & quoteShell(synced) & ";;\nesac\n" &
    "printf '%s' '{\"message\":\"Ready\",\"running\":false}' > \"$progress.tmp\"\n" &
    "mv \"$progress.tmp\" \"$progress\"\n")
  setFilePermissions(worker, {fpUserRead, fpUserWrite, fpUserExec})
  let recovering = startProcess(runtime / "mono-retro", args = @[
    "--library:" & root, "--config:" & configPath, "--theme:pocket", "--seconds:20"],
    options = {poParentStreams})
  defer:
    if recovering.running(): recovering.terminate()
    discard recovering.waitForExit(5000)
    recovering.close()
  window = findWindow(display, window)
  let recoveredDeadline = getMonoTime() + initDuration(seconds = 10)
  while not fileExists(synced) and getMonoTime() < recoveredDeadline: sleep(50)
  doAssert fileExists(synced)
  doAssert readFile(probeCount).strip() == "2"
  doAssert loadTheme(preferences) == LibraryTheme
  press(display, window, 0xff1b)
  doAssert recovering.waitForExit(5000) == 0

main()
