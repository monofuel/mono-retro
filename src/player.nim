import
  std/[monotimes, os, parseopt, posix, strutils, times],
  paddy, pixie, windy,
  retro/[libretro, playerclock, playerinput, playervideo]

const
  SaveIntervalSeconds = 5
  PollIntervalMs = 2
  Help = """Usage: mono-retro-player --core:PATH --rom:PATH --save-dir:DIR [--frames:N]
Silent desktop libretro player. Audio is consumed and discarded.
Arrows: D-pad. X/Z: A/B. A/S: L/R. Enter: Start. Backspace: Select.
Escape or window close exits. The first connected gamepad uses RetroPad positions.
Emulation pauses when the window is unfocused or minimized.
"""

var stopping = false

proc stopHandler(signal: cint) {.noconv.} =
  ## Let the main loop save and clean up outside the signal handler.
  stopping = true

proc main() =
  ## Run one silent desktop core with an independent save directory.
  var
    corePath, romPath, saveDirectory: string
    limit = 0'u64
    parser = initOptParser(commandLineParams())
  for kind, key, value in parser.getopt():
    if kind != cmdLongOption: raise newException(ValueError, "Expected a player option")
    case key
    of "help": stdout.write(Help); return
    of "core": corePath = value
    of "rom": romPath = value
    of "save-dir": saveDirectory = value
    of "frames":
      limit = parseBiggestUInt(value)
      if limit == 0: raise newException(ValueError, "Frame limit must be positive")
    else: raise newException(ValueError, "Unknown player option: " & key)
  if corePath.len == 0 or romPath.len == 0 or saveDirectory.len == 0:
    raise newException(ValueError, Help)
  let session = openCore(corePath, romPath, saveDirectory)
  defer: session.close()
  setLinuxBackend(X11Backend)
  let window = newWindow("mono-retro-player | " & $session.info.libraryName & " | " &
    romPath.extractFilename & " | SILENT", ivec2(720, 480), vsync = false)
  defer: window.close()
  initGamepads()
  defer: closeGamepads()
  posix.signal(SIGINT, stopHandler)
  posix.signal(SIGTERM, stopHandler)
  echo "Core: ", session.info.libraryName, " ", session.info.libraryVersion
  echo "Save: ", session.savePath
  echo "Audio: discarded; core rate: ", session.av.timing.fps
  var
    clock = newFrameClock(session.av.timing.fps, getMonoTime().ticks)
    fps = session.av.timing.fps
    lastSave = getMonoTime()
    canvas: Image
  while not stopping and not session.shutdown and (limit == 0 or session.frames < limit):
    pollEvents()
    if window.closed or window.closeRequested or window.buttonPressed[KeyEscape]: break
    let
      pads = pollGamepads()
      now = getMonoTime()
      size = window.framebufferSize
    if (now - lastSave).inSeconds >= SaveIntervalSeconds:
      session.save()
      lastSave = now
    if not window.focused or window.minimized or size.x <= 0 or size.y <= 0:
      session.buttons = 0
      clock.reset(now.ticks)
      sleep(PollIntervalMs)
      continue
    if now.ticks < clock.deadline:
      sleep(PollIntervalMs)
      continue
    var held: set[Button]
    for (key, button) in KeyboardButtons:
      if window.buttonDown[key]: held.incl key
    session.step(keyboardButtons(held) or gamepadButtons(pads))
    canvas = fitFrame(session.image, canvas, int(size.x), int(size.y), session.av.geometry.aspectRatio)
    window.presentPixels(canvas)
    if session.av.timing.fps != fps:
      fps = session.av.timing.fps
      clock = newFrameClock(fps, getMonoTime().ticks)
    clock.advance(getMonoTime().ticks)
  echo "Frames: ", session.frames, "; video: ", session.videoFrames,
    "; discarded audio frames: ", session.audioFrames

when isMainModule:
  main()
