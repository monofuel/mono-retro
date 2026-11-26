import
  std/[monotimes, os, times],
  pixie, windy,
  windy/platforms/linux/x11/[x, xevent, xlib],
  retro/[display, settings]

proc queryTree(d: xlib.Display, window: x.Window, root, parent: ptr x.Window,
    children: ptr ptr UncheckedArray[x.Window], count: ptr cuint): cint
    {.cdecl, importc: "XQueryTree", dynlib: libX11.}
proc fetchName(d: xlib.Display, window: x.Window, name: ptr cstring): cint
    {.cdecl, importc: "XFetchName", dynlib: libX11.}
proc clearArea(d: xlib.Display, window: x.Window, x, y: cint,
    width, height: cuint, exposures: cint): cint {.cdecl, importc: "XClearArea", dynlib: libX11.}
proc resizeWindow(d: xlib.Display, window: x.Window, width, height: cuint): cint
    {.cdecl, importc: "XResizeWindow", dynlib: libX11.}
proc mapWindow(d: xlib.Display, window: x.Window): cint {.cdecl, importc: "XMapWindow", dynlib: libX11.}
proc unmapWindow(d: xlib.Display, window: x.Window): cint {.cdecl, importc: "XUnmapWindow", dynlib: libX11.}
proc sendEvent(d: xlib.Display, window: x.Window, propagate: cint, mask: clong,
    event: ptr XEvent): cint {.cdecl, importc: "XSendEvent", dynlib: libX11.}
proc getImage(d: xlib.Display, window: x.Window, x, y: cint, width, height: cuint,
    planes: culong, format: cint): pointer {.cdecl, importc: "XGetImage", dynlib: libX11.}
proc getPixel(image: pointer, x, y: cint): culong {.cdecl, importc: "XGetPixel", dynlib: libX11.}
proc destroyImage(image: pointer): cint {.cdecl, importc: "XDestroyImage", dynlib: libX11.}
proc closeDisplay(d: xlib.Display): cint {.cdecl, importc: "XCloseDisplay", dynlib: libX11.}

proc main() =
  ## Exercise only an owned CPU window on an explicitly isolated software display.
  let
    address = getEnv("MONO_RETRO_TEST_DISPLAY")
    title = "MONO RETRO INERT REPAINT FIXTURE"
  doAssert address.len > 0 and getEnv("DISPLAY") == address
  var config = defaultSettings()
  config.display = "x11"
  let
    screen = openDisplay(config, ivec2(440, 480), windowTitles = @[title])
    connection = XOpenDisplay(address.cstring)
  defer: screen.close()
  doAssert connection != nil
  defer: discard closeDisplay(connection)
  var
    root, parent: x.Window
    children: ptr UncheckedArray[x.Window]
    count: cuint
    handle: x.Window
  doAssert queryTree(connection, connection.defaultRootWindow, addr root,
    addr parent, addr children, addr count) != 0
  for index in 0 ..< count.int:
    var name: cstring
    if fetchName(connection, children[index], addr name) != 0 and name != nil:
      if $name == title: handle = children[index]
      XFree(name)
  if children != nil: XFree(children)
  doAssert handle != 0
  template await(condition: untyped) =
    block:
      let deadline = getMonoTime() + initDuration(seconds = 2)
      var ready = condition
      while not ready and getMonoTime() < deadline:
        doAssert screen.poll(escapeCloses = false)
        sleep(5)
        ready = condition
      doAssert ready
  proc paint(rgb: uint32) =
    let
      image = newImage(screen.width(), screen.height())
      shade = rgbx(uint8(rgb shr 24), uint8((rgb shr 16) and 255),
        uint8((rgb shr 8) and 255), 255)
    image.fill(shade)
    screen.present(image)
  proc pixel(px, py: int): uint32 =
    let image = getImage(connection, handle, px.cint, py.cint, 1, 1, high(culong), 2)
    doAssert image != nil
    defer: discard destroyImage(image)
    uint32(getPixel(image, 0, 0) and 0xffffff)
  doAssert screen.poll(escapeCloses = false)
  doAssert screen.takeRedraw()
  paint(0xcc2244ff'u32)
  doAssert pixel(430, 470) == 0xcc2244
  for attempt in 0 ..< 5: doAssert screen.poll(escapeCloses = false)
  discard screen.takeRedraw()
  for attempt in 0 ..< 5:
    doAssert screen.poll(escapeCloses = false)
    doAssert not screen.takeRedraw(), "Idle polling must not demand continuous painting"
  # Damage arrives without any new menu state or input.
  discard clearArea(connection, handle, 0, 0, 0, 0, 1)
  connection.XFlush()
  await(screen.takeRedraw())
  paint(0x22aa44ff'u32)
  doAssert pixel(430, 470) == 0x22aa44
  # Grow the client well beyond its old right edge.
  discard resizeWindow(connection, handle, 720, 480)
  connection.XFlush()
  await(screen.width() == 720)
  await(screen.takeRedraw())
  paint(0x3366ccff'u32)
  doAssert pixel(700, 470) == 0x3366cc
  for kind in [xeFocusIn, xeFocusOut]:
    var event = XEvent(focus: XFocusChangeEvent(kind: kind, display: connection, window: handle))
    doAssert sendEvent(connection, handle, 0, FocusChangeMask, addr event) != 0
    connection.XFlush()
    await(screen.takeRedraw())
  doAssert not screen.window(0).focused
  paint(0xeebb33ff'u32)
  doAssert pixel(700, 470) == 0xeebb33
  discard unmapWindow(connection, handle)
  connection.XFlush()
  await(not screen.window(0).visible)
  discard screen.takeRedraw()
  paint(0x44bbccff'u32)
  doAssert not screen.takeRedraw()
  discard mapWindow(connection, handle)
  connection.XFlush()
  await(screen.takeRedraw())
  paint(0x44bbccff'u32)
  doAssert pixel(700, 470) == 0x44bbcc

main()
