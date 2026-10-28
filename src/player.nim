import
  std/[monotimes, os, parseopt, posix, strutils, times],
  paddy, pixie, windy,
  retro/[anbernic, display, libretro, playeraudio, playerclock, playerinput,
    playervideo, settings]

const
  SaveIntervalSeconds = 5
  PollIntervalMs = 2
  ExitHoldSeconds = 2
  Help = """Usage: mono-retro-player --core:PATH --rom:PATH --save-dir:DIR [--frames:N] [--mute]
Libretro player with Slappy audio. --mute opens no audio device.
Arrows: D-pad. X/Z: A/B. A/S: L/R. Enter: Start. Backspace: Select.
Escape or window close exits. The first connected gamepad uses RetroPad positions.
Hold Select+Start for two seconds to exit. L2 swaps dual screens.
Device detection selects the display; --device and --display override it.
Desktop emulation pauses when the window is unfocused or minimized.
"""

var stopping = false

proc stopHandler(signal: cint) {.noconv.} =
  ## Let the main loop save and clean up outside the signal handler.
  stopping = true

proc main() =
  ## Run one desktop core with an independent save directory.
  var
    corePath, romPath, saveDirectory: string
    limit = 0'u64
    muted = false
    displayArguments = @["--device:auto"]
    parser = initOptParser(commandLineParams())
  for kind, key, value in parser.getopt():
    if kind != cmdLongOption: raise newException(ValueError, "Expected a player option")
    case key
    of "help": stdout.write(Help); return
    of "core": corePath = value
    of "rom": romPath = value
    of "save-dir": saveDirectory = value
    of "mute": muted = true
    of "device", "display": displayArguments.add("--" & key & ":" & value)
    of "frames":
      limit = parseBiggestUInt(value)
      if limit == 0: raise newException(ValueError, "Frame limit must be positive")
    else: raise newException(ValueError, "Unknown player option: " & key)
  if corePath.len == 0 or romPath.len == 0 or saveDirectory.len == 0:
    raise newException(ValueError, Help)
  let session = openCore(corePath, romPath, saveDirectory, captureAudio = not muted)
  defer: session.close()
  var settings = parseSettings(displayArguments, detectDevice())
  settings.title = "mono-retro-player | " & $session.info.libraryName & " | " &
    romPath.extractFilename & (if muted: " | MUTED" else: "")
  let
    desktop = settings.displayBackend() == "x11"
    screen = openDisplay(settings,
      ivec2(session.av.geometry.baseWidth.int32, session.av.geometry.baseHeight.int32))
  defer: screen.close()
  var
    activeScreen = screen.count() - 1
    black: seq[Image]
  for index in 0 ..< screen.count():
    let image = newImage(screen.width(index), screen.height(index))
    image.fill(rgbx(0, 0, 0, 255))
    black.add(image)
    screen.window(index).presentPixels(image)
  initGamepads()
  defer: closeGamepads()
  var sound: PlayerAudio
  defer: sound.close()
  if not muted: sound = newPlayerAudio(session.av.timing.sampleRate)
  posix.signal(SIGINT, stopHandler)
  posix.signal(SIGTERM, stopHandler)
  echo "Core: ", session.info.libraryName, " ", session.info.libraryVersion
  echo "Save: ", session.savePath
  echo "Audio: ", (if muted: "muted" else: "Slappy"), "; core rate: ", session.av.timing.fps
  var
    clock = newFrameClock(session.av.timing.fps, getMonoTime().ticks)
    fps = session.av.timing.fps
    lastSave = getMonoTime()
    canvas: Image
    paused = false
    exitHeld = false
    exitStarted: MonoTime
  while not stopping and not session.shutdown and (limit == 0 or session.frames < limit):
    if not screen.poll(): break
    if sound != nil: sound.pump()
    var pads = pollGamepads()
    for pad in pads.mitems: pad = pad.mapAnbernic()
    let
      pad = firstGamepad(pads)
      now = getMonoTime()
    if pad.button(GamepadSelect) and pad.button(GamepadStart):
      if not exitHeld: exitStarted = now
      exitHeld = true
      if (now - exitStarted).inSeconds >= ExitHoldSeconds: break
    else:
      exitHeld = false
    if screen.count() > 1 and pad.buttonPressed(GamepadL2):
      screen.window(activeScreen).presentPixels(black[activeScreen])
      activeScreen = (activeScreen + 1) mod screen.count()
    let
      window = screen.window(activeScreen)
      size = window.framebufferSize
    if (now - lastSave).inSeconds >= SaveIntervalSeconds:
      session.save()
      lastSave = now
    if (desktop and (not window.focused or window.minimized)) or size.x <= 0 or size.y <= 0:
      if not paused and sound != nil: sound.reset()
      paused = true
      session.buttons = 0
      clock.reset(now.ticks)
      sleep(PollIntervalMs)
      continue
    paused = false
    if now.ticks < clock.deadline:
      sleep(PollIntervalMs)
      continue
    var held: set[Button]
    for (key, button) in KeyboardButtons:
      if window.buttonDown[key]: held.incl key
    var buttons = keyboardButtons(held) or gamepadButtons(pads)
    if screen.count() > 1: buttons = buttons and not (1'u16 shl 12)
    session.step(buttons)
    if sound != nil: sound.submit(session.takeAudio(), session.av.timing.sampleRate)
    canvas = fitFrame(session.image, canvas, int(size.x), int(size.y))
    window.presentPixels(canvas)
    if session.av.timing.fps != fps:
      fps = session.av.timing.fps
      clock = newFrameClock(fps, getMonoTime().ticks)
    clock.advance(getMonoTime().ticks)
  echo "Frames: ", session.frames, "; video: ", session.videoFrames,
    "; audio frames: ", session.audioFrames

when isMainModule:
  main()
