import
  std/[monotimes, os, osproc, strutils, tempfiles, times],
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

proc findWindow(d: Display): Window =
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
          let matched = ($name).startsWith("mono-retro-player |")
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

proc main() =
  ## Check presentation, input, pausing and shutdown on isolated Xvfb.
  let
    testDisplay = getEnv("MONO_RETRO_TEST_DISPLAY")
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
  for mode in 0 .. 2:
    if fileExists(trace): removeFile(trace)
    putEnv("ALSOFT_DRIVERS", if mode == 2: "mono-retro-no-such-driver" else: "null")
    var arguments = @[
      "--core:" & absolutePath("build/player-fixture.so"), "--rom:" & rom,
      "--save-dir:" & directory / "saves"]
    if mode == 2: arguments.add("--mute")
    let process = startProcess(absolutePath("build/mono-retro-player"),
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
  if paramCount() == 2:
    putEnv("ALSOFT_DRIVERS", "null")
    let process = startProcess(absolutePath("build/mono-retro-player"), args = [
      "--core:" & absolutePath(paramStr(1)), "--rom:" & absolutePath(paramStr(2)),
      "--save-dir:" & directory / "mgba", "--frames:180"], options = {poParentStreams})
    defer:
      if process.running(): process.terminate()
      discard process.waitForExit(5000)
      process.close()
    let
      window = findWindow(d)
      started = getMonoTime()
    d.XSetInputFocus(window, rtRoot)
    d.XFlush()
    doAssert process.waitForExit(10000) == 0
    let elapsed = (getMonoTime() - started).inMilliseconds
    doAssert elapsed > 2700 and elapsed < 5000, "Unexpected frame pacing: " & $elapsed & "ms"
    let savePath = directory / "mgba" / (paramStr(2).splitFile.name & ".srm")
    doAssert getFileSize(savePath) > 0

main()
