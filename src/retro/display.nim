import
  std/strutils,
  windy,
  ./[input, pattern, settings, touch]

type
  Display* = ref object
    windows: seq[Window]
    backend: string
    touch*: TouchState

proc displayBackend*(settings: Settings): string =
  if settings.display != "auto": return settings.display
  when HasX11: "x11"
  elif HasFbdev: "fbdev"
  else: "drm"

proc close*(display: Display) =
  var errors: seq[string]
  for window in display.windows:
    try:
      window.close()
    except CatchableError as error:
      errors.add error.msg
    finally:
      window.onTouch = nil
  display.windows.setLen(0)
  if errors.len > 0:
    raise newException(IOError, errors.join("; "))

proc openDisplay*(settings: Settings, initialSize = ivec2(720, 480)): Display =
  result = Display(backend: settings.displayBackend())
  let display = result
  let backend = case result.backend
    of "x11": X11Backend
    of "fbdev": FbdevBackend
    of "drm": DrmBackend
    else: raise newException(ValueError, "Unknown display backend")
  setLinuxBackend(backend)
  try:
    let count = if backend == FbdevBackend: 1 else: max(1, settings.outputs.len)
    for index in 0 ..< count:
      var options = LinuxWindowOptions(rotation: settings.rotation,
        touchRotation: settings.touchRotation)
      if backend == FbdevBackend: options.device = settings.framebuffer
      elif backend == DrmBackend:
        options.device = settings.drmDevice
        if settings.outputs.len > index: options.output = settings.outputs[index]
      if index == 1 and backend != X11Backend and settings.touchName.len > 0:
        let paths = inputPaths(@[settings.touchName])
        if paths.len != 1:
          raise newException(IOError, "Expected exactly one touchscreen: " & settings.touchName)
        options.touchDevice = paths[0]
      let window = newWindow(settings.title, initialSize, vsync = false,
        linuxOptions = options)
      display.windows.add window
      let size = window.framebufferSize
      if index == 1:
        display.touch = TouchState(enabled: options.touchDevice.len > 0,
          multitouch: true, minimumX: 0, maximumX: size.x - 1,
          minimumY: 0, maximumY: size.y - 1)
        window.onTouch = proc(event: TouchEvent) =
          var found = -1
          for index, contact in display.touch.contacts:
            if contact.id == event.contact.id: found = index
          let contact = touch.TouchContact(id: event.contact.id,
            x: int32(event.contact.position.x), y: int32(event.contact.position.y),
            active: event.phase in {TouchBegin, TouchMove})
          if event.phase in {TouchEnd, TouchCancel}:
            if found >= 0: display.touch.contacts.delete(found)
          elif found >= 0: display.touch.contacts[found] = contact
          else: display.touch.contacts.add contact
          if contact.active:
            display.touch.samples.add contact
            if display.touch.samples.len > 256:
              display.touch.samples.delete(0)
  except:
    result.close()
    raise

proc count*(display: Display): int = display.windows.len
proc width*(display: Display, index = 0): int = int(display.windows[index].framebufferSize.x)
proc height*(display: Display, index = 0): int = int(display.windows[index].framebufferSize.y)

proc window*(display: Display, index = 0): Window =
  ## Access a screen's public Windy input interface.
  display.windows[index]

proc poll*(display: Display, escapeCloses = true): bool =
  pollEvents()
  for window in display.windows:
    if window.closeRequested or window.closed or
        (escapeCloses and window.buttonPressed[KeyEscape]):
      return false
  true

proc present*(display: Display, canvas: Canvas, index = 0) =
  display.windows[index].presentPixels(canvas)

proc describe*(display: Display, index: int): string =
  display.backend & " " & $display.width(index) & "x" & $display.height(index)
