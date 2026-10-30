import
  std/[monotimes, os, osproc, strutils, tempfiles, times, uri],
  vmath,
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
proc getImage(d: Display, window: Window, x, y: cint, width, height: cuint,
    planes: culong, format: cint): pointer {.cdecl, importc: "XGetImage", dynlib: libX11.}
proc getPixel(image: pointer, x, y: cint): culong {.cdecl, importc: "XGetPixel", dynlib: libX11.}
proc destroyImage(image: pointer): cint {.cdecl, importc: "XDestroyImage", dynlib: libX11.}

proc openDisplay(name: string): Display =
  ## Allow an isolated Xvfb process to finish starting before connecting.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    result = XOpenDisplay(name.cstring)
    if result != nil: return
    sleep(10)
  raise newException(IOError, "Cannot connect to the isolated X11 test display")

proc findWindow(d: Display, suffix = ""): Window =
  ## Locate the child's window on an isolated test display.
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
          let matched = ($name).startsWith("mono-retro-player |") and ($name).endsWith(suffix)
          XFree(name)
          if matched:
            var attributes: XWindowAttributes
            d.XGetWindowAttributes(children[index], addr attributes)
            if attributes.map_state == IsViewable: return children[index]
    finally:
      if children != nil: XFree(children)
    sleep(10)
  raise newException(IOError, "Player did not create its X11 window")

proc key(d: Display, window: Window, symbol: culong, down: bool) =
  ## Send keyboard events through Windy's X11 backend.
  var event = XEvent(key: XKeyEvent(kind: if down: xeKeyPress else: xeKeyRelease,
    display: d, window: window, root: d.defaultRootWindow,
    keycode: keycode(d, symbol).cuint, same_screen: 1))
  doAssert sendEvent(d, window, 0, if down: 1 else: 2, addr event) != 0
  d.XFlush()

proc frameCount(trace: string): int =
  ## Count completed video callbacks in the fixture's trace.
  if fileExists(trace): result = readFile(trace).count("video_returned=")

proc waitFrames(trace: string, count: int) =
  ## Wait for observable frame progress with a bounded failure deadline.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while frameCount(trace) < count:
    doAssert getMonoTime() < deadline, "Player stopped producing frames"
    sleep(10)

proc mouse(d: Display, window: Window, x, y: int32, button = -1) =
  ## Inject mouse movement and optional left-button edges into an isolated window.
  var event = XEvent(motion: XMotionEvent(kind: xeMotion, display: d,
    window: window, root: d.defaultRootWindow, pos: ivec2(x, y), same_screen: 1))
  doAssert sendEvent(d, window, 0, 1 shl 6, addr event) != 0
  if button >= 0:
    event = XEvent(button: XButtonEvent(kind: if button == 1: xeButtonPress else: xeButtonRelease,
      display: d, window: window, root: d.defaultRootWindow,
      pos: ivec2(x, y), button: 1, same_screen: 1))
    doAssert sendEvent(d, window, 0, if button == 1: 4 else: 8, addr event) != 0
  d.XFlush()

proc lastValue(trace, key: string): int =
  ## Read a field from the latest frame whose video callback completed.
  let contents = readFile(trace)
  result = -1
  for line in contents[0 ..< contents.rfind("video_returned=")].splitLines():
    if line.startsWith(key & "="): result = parseInt(line[key.len + 1 .. ^1])

proc closeWindow(d: Display, window: Window) =
  ## Ask the application to close through the normal window-manager protocol.
  var event = XEvent(client: XClientMessageEvent(kind: xeClientMessage,
    display: d, window: window, message_type: d.XInternAtom("WM_PROTOCOLS", 0), format: 32))
  event.client.data.l[0] = clong(d.XInternAtom("WM_DELETE_WINDOW", 0))
  doAssert sendEvent(d, window, 0, 0, addr event) != 0
  d.XFlush()

proc testDs(d: Display, directory: string) =
  ## Verify DS screen routing, mouse coordinates, focus and either-window exit.
  let rom = directory / "ds.test"
  putEnv("ALSOFT_DRIVERS", "null")
  for mode in 0 .. 5:
    let
      earthbound = mode >= 3
      separate = mode != 0
      panelHeight = if earthbound: 224 else: 192
      trace = directory / ("ds-trace-" & $mode)
      layout = if separate: "separate" else: "combined"
    writeFile(rom, if mode == 5: "G" elif earthbound: "E" else: "N")
    putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
    let process = startProcess(absolutePath("build/mono-retro-player"), args = [
      "--core:" & absolutePath("build/player-fixture.so"), "--rom:" & rom,
      "--save-dir:" & directory / ("ds-save-" & $mode),
      (if earthbound: "--earthbound-ds" else: "--ds-layout:" & layout)],
      options = {poParentStreams})
    defer:
      if process.running(): process.terminate()
      discard process.waitForExit(5000)
      process.close()
    let
      top = findWindow(d, if earthbound: " | Game" elif separate: " | Top" else: "")
      touch = if earthbound: findWindow(d, " | Party")
        elif separate: findWindow(d, " | Touch") else: top
    d.XMoveWindow(top, 0, 0)
    if separate: d.XMoveWindow(touch, 400, 0)
    d.XSetInputFocus(touch, rtRoot)
    d.XSync(false)
    waitFrames(trace, 3)
    var attributes: XWindowAttributes
    d.XGetWindowAttributes(touch, addr attributes)
    doAssert attributes.size == (if earthbound: ivec2(512, 448)
      else: ivec2(256, if separate: 192 else: 384))
    let captured = getImage(d, top, 0, 0, 256, 192, high(culong), 2)
    doAssert captured != nil
    doAssert (getPixel(captured, 32, 32) and 0xffffff) == 0xff0000
    discard destroyImage(captured)
    d.XResizeWindow(touch, 522, if separate: panelHeight.cuint * 2 + 10 else: 778)
    d.XSync(false)
    waitFrames(trace, frameCount(trace) + 3)
    let
      touchY = if separate: 133'i32 else: 517'i32
      pixels = getImage(d, touch, 0, 0, 522,
        (if separate: panelHeight.cuint * 2 + 10 else: 778), high(culong), 2)
    doAssert pixels != nil
    doAssert (getPixel(pixels, 0, 0) and 0xffffff) == 0
    doAssert (getPixel(pixels, 133, touchY) and 0xffffff) == 0x0000ff
    discard destroyImage(pixels)
    mouse(d, touch, 133, touchY, 1)
    waitFrames(trace, frameCount(trace) + 3)
    doAssert lastValue(trace, "pointer_pressed") == 1,
      "Pointer X=" & $lastValue(trace, "pointer_x") & " Y=" & $lastValue(trace, "pointer_y")
    let
      pointerX = cast[int16](lastValue(trace, "pointer_x").uint16).int
      pointerY = cast[int16](lastValue(trace, "pointer_y").uint16).int
    doAssert (pointerX + 32767) * 256 div 65534 == 64
    doAssert (pointerY + 32767) * (panelHeight * 2) div 65534 == panelHeight + 64
    mouse(d, touch, 173, touchY)
    waitFrames(trace, frameCount(trace) + 3)
    doAssert lastValue(trace, "pointer_pressed") == 1
    doAssert lastValue(trace, "pointer_x") != cast[uint16](int16(pointerX)).int
    mouse(d, touch, 0, 0)
    waitFrames(trace, frameCount(trace) + 3)
    doAssert lastValue(trace, "pointer_pressed") == 0
    mouse(d, touch, 133, touchY)
    waitFrames(trace, frameCount(trace) + 3)
    doAssert lastValue(trace, "pointer_pressed") == (if earthbound: 0 else: 1)
    mouse(d, touch, 133, touchY, 0)
    waitFrames(trace, frameCount(trace) + 3)
    doAssert lastValue(trace, "pointer_pressed") == 0
    mouse(d, touch, 133, touchY, 1)
    waitFrames(trace, frameCount(trace) + 3)
    doAssert lastValue(trace, "pointer_pressed") == 1
    mouse(d, touch, 133, touchY, 0)
    if separate:
      d.XSetInputFocus(top, rtRoot)
      d.XFlush()
      waitFrames(trace, frameCount(trace) + 3)
      mouse(d, top, 64, 64, 1)
      key(d, top, 0x77, true)
      waitFrames(trace, frameCount(trace) + 3)
      doAssert lastValue(trace, "pointer_pressed") == 0
      doAssert lastValue(trace, "input") == 512
      key(d, top, 0x77, false)
      mouse(d, top, 64, 64, 0)
      d.XGetWindowAttributes(top, addr attributes)
      doAssert attributes.size == (if earthbound: ivec2(512, 448) else: ivec2(256, 192))
      if earthbound:
        for (symbol, bit) in [(0xff55.culong, 12), (0xff56.culong, 13)]:
          key(d, top, symbol, true)
          waitFrames(trace, frameCount(trace) + 3)
          doAssert lastValue(trace, "input") == (1 shl bit)
          key(d, top, symbol, false)
          waitFrames(trace, frameCount(trace) + 3)
    d.XSetInputFocus(d.defaultRootWindow, rtRoot)
    d.XFlush()
    sleep(100)
    let paused = frameCount(trace)
    sleep(150)
    doAssert frameCount(trace) == paused
    d.XSetInputFocus(touch, rtRoot)
    d.XFlush()
    waitFrames(trace, paused + 3)
    doAssert lastValue(trace, "pointer_pressed") == 0
    closeWindow(d, if mode in [2, 4]: touch else: top)
    doAssert process.waitForExit(5000) == 0
    doAssert readFile(trace).endsWith("unload=1\ndeinit=1\n")
    if mode == 5:
      doAssert readFile(trace).contains("xbgr_accepted=" &
        (if cpuEndian == littleEndian: "1" else: "0") & "\n")
  delEnv("MONO_RETRO_FIXTURE_TRACE")

proc dropFile(d: Display, window: Window, path: string) =
  ## Deliver a real URI-list selection through Windy's X11 file-drop event path.
  let
    property = d.XInternAtom("windy_xdndTargetProperty", 0)
    target = d.XInternAtom("text/uri-list", 0)
    uri = "file://" & encodeUrl(path, false).replace("%2F", "/") & "\r\n"
  d.XChangeProperty(window, property, target, 8, pmReplace, uri.cstring, uri.len.cint)
  var event = XEvent(selection: XSelectionEvent(kind: xeSelection, display: d,
    requestor: window, selection: d.XInternAtom("XdndSelection", 0),
    target: target, property: property))
  doAssert sendEvent(d, window, 0, 0, addr event) != 0
  d.XFlush()

proc waitImports(trace: string, count: int) =
  ## Wait for the core to acknowledge a state through the actual ABI.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not fileExists(trace) or readFile(trace).count("state_loaded=42\n") < count:
    doAssert getMonoTime() < deadline, "Dropped state did not reach the core"
    sleep(10)

proc testStateDrops(d: Display, directory: string) =
  ## Exercise startup import and successful/rejected drops on single and dual windows.
  let
    rom = directory / "drop.test"
    state = directory / "screen state with spaces.png"
    bad = directory / "plain bad state.png"
  writeFile(state, "fixture-state")
  writeFile(bad, "bad-state")
  for dual in [false, true]:
    let
      trace = directory / (if dual: "drop-dual-trace" else: "drop-single-trace")
      saves = directory / (if dual: "drop-dual-saves" else: "drop-single-saves")
    putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
    writeFile(rom, if dual: "E" else: "T")
    createDir(saves)
    writeFile(saves / "drop.srm", repeat('\0', 4) & char(99) & repeat('\0', 11))
    var arguments = @[
      "--core:" & absolutePath("build/player-fixture.so"), "--rom:" & rom,
      "--save-dir:" & saves, "--load-state:" & state]
    if dual: arguments.add("--earthbound-ds")
    let process = startProcess(absolutePath("build/mono-retro-player"), args = arguments,
      options = {poParentStreams})
    defer:
      if process.running(): process.terminate()
      discard process.waitForExit(5000)
      process.close()
    let
      top = findWindow(d, if dual: " | Game" else: "")
      bottom = if dual: findWindow(d, " | Party") else: top
    d.XMoveWindow(top, 0, 0)
    if dual: d.XMoveWindow(bottom, 600, 0)
    d.XSetInputFocus(top, rtRoot)
    d.XFlush()
    waitFrames(trace, 3)
    doAssert readFile(trace).contains("loaded_byte=42\n")
    var imports = 1
    for window in (if dual: @[top, bottom] else: @[top]):
      d.XSetInputFocus(d.defaultRootWindow, rtRoot)
      d.XSync(false)
      sleep(100)
      let before = frameCount(trace)
      dropFile(d, window, state)
      inc imports
      waitImports(trace, imports)
      waitFrames(trace, before + 3)
      doAssert process.running()
      let beforeBad = frameCount(trace)
      dropFile(d, window, bad)
      waitFrames(trace, beforeBad + 3)
      doAssert process.running()
      doAssert readFile(trace).count("state_loaded=42\n") == imports
      let beforeMissing = frameCount(trace)
      dropFile(d, window, directory / "missing screenstate.png")
      waitFrames(trace, beforeMissing + 3)
      doAssert process.running()
      doAssert readFile(trace).count("state_loaded=42\n") == imports
    closeWindow(d, bottom)
    doAssert process.waitForExit(5000) == 0
    doAssert readFile(saves / "drop.srm")[4] == char(123)
  delEnv("MONO_RETRO_FIXTURE_TRACE")

proc main() =
  ## Check presentation, input, pausing and shutdown on isolated Xvfb.
  let
    testDisplay = getEnv("MONO_RETRO_TEST_DISPLAY")
    legacyPlayer = getEnv("MONO_RETRO_LEGACY_PLAYER")
    directory = createTempDir("player-x11-", "")
    trace = directory / "trace"
    rom = directory / "fixture.test"
  doAssert testDisplay.len > 0, "Set MONO_RETRO_TEST_DISPLAY to an isolated Xvfb display."
  putEnv("DISPLAY", testDisplay)
  putEnv("ALSOFT_DRIVERS", "mono-retro-no-such-driver")
  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  defer:
    delEnv("MONO_RETRO_FIXTURE_TRACE")
    removeDir(directory)
  writeFile(rom, "T")
  let d = openDisplay(testDisplay)
  defer: discard closeDisplay(d)
  block:
    let process = startProcess(absolutePath("build/mono-retro-player"), args = [
      "--core:" & absolutePath("build/player-fixture.so"), "--rom:" & rom,
      "--save-dir:" & directory / "audio-error"], options = {poParentStreams})
    defer:
      if process.running(): process.terminate()
      discard process.waitForExit(5000)
      process.close()
    doAssert process.waitForExit(5000) > 0
    doAssert readFile(trace).endsWith("unload=1\ndeinit=1\n")
    doAssert getFileSize(directory / "audio-error/fixture.srm") == 16
  for mode in 0 .. (if legacyPlayer.len > 0: 4 else: 3):
    if fileExists(trace): removeFile(trace)
    writeFile(rom, if mode >= 3: "X" else: "T")
    putEnv("ALSOFT_DRIVERS", if mode == 2: "mono-retro-no-such-driver" else: "null")
    var arguments = @[
      "--core:" & absolutePath("build/player-fixture.so"), "--rom:" & rom,
      "--save-dir:" & directory / "saves"]
    if mode == 2: arguments.add("--mute")
    let player = if mode == 4: absolutePath(legacyPlayer) else: absolutePath("build/mono-retro-player")
    let process = startProcess(player,
      args = arguments, options = {poParentStreams})
    defer:
      if process.running(): process.terminate()
      discard process.waitForExit(5000)
      process.close()
    let window = findWindow(d)
    var attributes: XWindowAttributes
    d.XGetWindowAttributes(window, addr attributes)
    doAssert attributes.size.x == 3 and attributes.size.y == 2
    d.XSetInputFocus(window, rtRoot)
    d.XFlush()
    waitFrames(trace, 3)
    d.XResizeWindow(window, 11, 8)
    d.XFlush()
    waitFrames(trace, frameCount(trace) + 3)
    let image = getImage(d, window, 0, 0, 11, 8, high(culong), 2)
    doAssert image != nil
    try:
      doAssert (getPixel(image, 0, 0) and 0xffffff) == 0
      doAssert (getPixel(image, 1, 1) and 0xffffff) == 0xff0000
      doAssert (getPixel(image, 3, 3) and 0xffffff) == 0xff0000
      doAssert (getPixel(image, 4, 1) and 0xffffff) == 0x00ff00
      doAssert (getPixel(image, 6, 3) and 0xffffff) == 0x00ff00
      doAssert (getPixel(image, 7, 1) and 0xffffff) == 0x0000ff
      doAssert (getPixel(image, 9, 3) and 0xffffff) == 0x0000ff
      doAssert (getPixel(image, 10, 1) and 0xffffff) == 0
      doAssert (getPixel(image, 1, 4) and 0xffffff) == 0xffffff
      doAssert (getPixel(image, 1, 7) and 0xffffff) == 0
    finally:
      discard destroyImage(image)
    key(d, window, 0x78, true)
    waitFrames(trace, frameCount(trace) + 3)
    doAssert readFile(trace).contains("input=256\n")
    key(d, window, 0x78, false)
    waitFrames(trace, frameCount(trace) + 3)
    d.XSetInputFocus(d.defaultRootWindow, rtRoot)
    d.XFlush()
    sleep(100)
    let paused = frameCount(trace)
    sleep(150)
    doAssert frameCount(trace) == paused
    d.XSetInputFocus(window, rtRoot)
    d.XFlush()
    waitFrames(trace, paused + 3)
    doAssert readFile(trace).contains("input=0\n")
    if mode == 1: process.terminate()
    else: key(d, window, 0xff1b, true)
    doAssert process.waitForExit(5000) == 0
    let contents = readFile(directory / "saves/fixture.srm")
    doAssert contents.len == 16 and contents[4] == char(123)
    doAssert readFile(trace).endsWith("unload=1\ndeinit=1\n")
    if mode >= 3:
      doAssert readFile(trace).contains("xbgr_accepted=" &
        (if mode == 3 and cpuEndian == littleEndian: "1" else: "0") & "\n")
  testDs(d, directory)
  testStateDrops(d, directory)
  if paramCount() == 3:
    putEnv("ALSOFT_DRIVERS", "null")
    let seed = readFile(paramStr(3))
    for layout in ["combined", "separate"]:
      let saves = directory / ("melonds-" & layout)
      createDir(saves)
      copyFile(paramStr(3), saves / paramStr(2).splitFile.name & ".srm")
      let process = startProcess(absolutePath("build/mono-retro-player"), args = [
        "--core:" & absolutePath(paramStr(1)), "--rom:" & absolutePath(paramStr(2)),
        "--save-dir:" & saves, "--ds-layout:" & layout, "--frames:180"],
        options = {poParentStreams})
      defer:
        if process.running(): process.terminate()
        discard process.waitForExit(5000)
        process.close()
      let window = findWindow(d, if layout == "separate": " | Touch" else: "")
      d.XSetInputFocus(window, rtRoot)
      d.XFlush()
      doAssert process.waitForExit(30000) == 0
      doAssert getFileSize(saves / paramStr(2).splitFile.name & ".srm") > 0
    doAssert readFile(paramStr(3)) == seed
  if paramCount() in [2, 4]:
    if paramCount() == 4: doAssert paramStr(3) == "--load-state"
    putEnv("ALSOFT_DRIVERS", "null")
    let earthbound = paramStr(1).extractFilename.startsWith("decompbound_libretro")
    for dual in 0 .. (if earthbound: 1 else: 0):
      let saves = directory / (if dual == 1: "earthbound-ds" else: "single")
      var arguments = @[
        "--core:" & absolutePath(paramStr(1)), "--rom:" & absolutePath(paramStr(2)),
        "--save-dir:" & saves, "--frames:180"]
      if dual == 1: arguments.add("--earthbound-ds")
      if paramCount() == 4: arguments.add("--load-state:" & absolutePath(paramStr(4)))
      let process = startProcess(absolutePath("build/mono-retro-player"), args = arguments,
        options = {poParentStreams})
      defer:
        if process.running(): process.terminate()
        discard process.waitForExit(5000)
        process.close()
      let
        window = findWindow(d, if dual == 1: " | Party" else: "")
        started = getMonoTime()
      d.XSetInputFocus(window, rtRoot)
      d.XFlush()
      doAssert process.waitForExit(10000) == 0
      let elapsed = (getMonoTime() - started).inMilliseconds
      doAssert elapsed > 2700 and elapsed < 5000, "Unexpected frame pacing: " & $elapsed & "ms"
      let savePath = saves / (paramStr(2).splitFile.name & ".srm")
      doAssert getFileSize(savePath) > 0

main()
