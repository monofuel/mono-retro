import
  std/[monotimes, os, parseopt, posix, strutils, times],
  paddy, pixie, windy,
  retro/[anbernic, display, libretro, playeraudio, playerclock, playerds, playerinput,
    playervideo, settings]

const
  SaveIntervalSeconds = 5
  PollIntervalMs = 2
  NanosecondsPerMillisecond = 1_000_000
  ExitHoldSeconds = 2
  Help = """Usage: mono-retro-player --core:PATH --rom:PATH --save-dir:DIR [--frames:N] [--mute]
Libretro player with Slappy audio. --mute opens no audio device.
Arrows: D-pad. X/Z: A/B. A/S: L/R. Enter: Start. Backspace: Select.
Escape or window close exits. The first connected gamepad uses RetroPad positions.
DS: --ds-layout:combined|separate. W/Q: X/Y. Mouse or native touch: lower screen.
Native DS requires two DRM outputs and separate layout.
Hold Select+Start for two seconds to exit. L2 swaps screens for single-screen games.
Device detection selects the display; --device and --display override it.
Desktop emulation pauses when the window is unfocused or minimized.
"""

var stopping = false

proc stopHandler(signal: cint) {.noconv.} =
  ## Let the main loop save and clean up outside the signal handler.
  stopping = true

proc main() =
  ## Run one core with an independent save directory.
  var
    corePath, romPath, saveDirectory: string
    limit = 0'u64
    muted = false
    dsLayout = NoDsLayout
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
    of "ds-layout": dsLayout = parseDsLayout(value)
    of "device", "display": displayArguments.add("--" & key & ":" & value)
    of "frames":
      limit = parseBiggestUInt(value)
      if limit == 0: raise newException(ValueError, "Frame limit must be positive")
    else: raise newException(ValueError, "Unknown player option: " & key)
  if corePath.len == 0 or romPath.len == 0 or saveDirectory.len == 0:
    raise newException(ValueError, Help)
  var settings = parseSettings(displayArguments, detectDevice())
  let desktop = settings.displayBackend() == "x11"
  validateDsDisplay(dsLayout, settings.displayBackend(), settings.outputs.len)
  let session = openCore(corePath, romPath, saveDirectory, captureAudio = not muted,
    options = (if dsLayout == NoDsLayout: @[] else: DsOptions))
  defer: session.close()
  if dsLayout != NoDsLayout:
    validateDsFrame(session.av.geometry.baseWidth.int, session.av.geometry.baseHeight.int)
  settings.title = "mono-retro-player | " & $session.info.libraryName & " | " &
    romPath.extractFilename & (if muted: " | MUTED" else: "")
  let
    windowTitles = case (if desktop: dsLayout else: NoDsLayout)
      of NoDsLayout: newSeq[string]()
      of CombinedDs: @[settings.title]
      of SeparateDs: @[settings.title & " | Top", settings.title & " | Touch"]
    initialSize = if dsLayout == SeparateDs: ivec2(DsWidth, DsHeight)
      else: ivec2(session.av.geometry.baseWidth.int32, session.av.geometry.baseHeight.int32)
    screen = openDisplay(settings,
      initialSize, windowTitles)
  defer: screen.close()
  validateDsDisplay(dsLayout, settings.displayBackend(), screen.count())
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
    canvases = newSeq[Image](screen.count())
    dsImages: array[2, Image]
    paused = false
    exitHeld = false
    exitStarted: MonoTime
    stylus: DsStylus
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
    if not desktop and dsLayout == NoDsLayout and screen.count() > 1 and pad.buttonPressed(GamepadL2):
      screen.window(activeScreen).presentPixels(black[activeScreen])
      activeScreen = (activeScreen + 1) mod screen.count()
    var focusedIndex = -1
    if desktop:
      for index in 0 ..< screen.count():
        let window = screen.window(index)
        if window.focused and not window.minimized and
            window.framebufferSize.x > 0 and window.framebufferSize.y > 0:
          focusedIndex = index
    let
      inputScreen = if desktop and focusedIndex >= 0: focusedIndex else: activeScreen
      window = screen.window(inputScreen)
      size = window.framebufferSize
    if (now - lastSave).inSeconds >= SaveIntervalSeconds:
      session.save()
      lastSave = now
    if (desktop and focusedIndex < 0) or size.x <= 0 or size.y <= 0:
      if not paused and sound != nil: sound.reset()
      paused = true
      session.buttons = 0
      session.pointerInput = PointerInput()
      clock.reset(now.ticks)
      sleep(PollIntervalMs)
      continue
    paused = false
    if now.ticks < clock.deadline:
      let remainingMs = int((clock.deadline - now.ticks) div NanosecondsPerMillisecond)
      sleep(min(PollIntervalMs, remainingMs))
      continue
    var held: set[Button]
    for (key, button) in KeyboardButtons:
      if window.buttonDown[key]: held.incl key
    var buttons = keyboardButtons(held) or gamepadButtons(pads)
    if not desktop and dsLayout == NoDsLayout and screen.count() > 1:
      buttons = buttons and not (1'u16 shl 12)
    let pointerInput = if dsLayout == SeparateDs and not desktop:
        nativeDsPointer(stylus, screen.touch.contacts, screen.width(1), screen.height(1))
      elif dsLayout != NoDsLayout:
        dsPointer(dsLayout, inputScreen, size.x.int, size.y.int,
          window.mousePos.x.int, window.mousePos.y.int, window.buttonDown[MouseLeft])
      else: PointerInput()
    session.step(buttons, pointerInput)
    if sound != nil: sound.submit(session.takeAudio(), session.av.timing.sampleRate)
    if dsLayout != NoDsLayout and session.image != nil:
      validateDsFrame(session.image.width, session.image.height)
    if dsLayout == SeparateDs and session.image != nil:
      for index in 0 .. 1:
        let
          output = screen.window(index)
          outputSize = output.framebufferSize
        if (desktop and output.minimized) or outputSize.x <= 0 or outputSize.y <= 0: continue
        dsImages[index] = dsScreen(session.image, dsImages[index], index)
        canvases[index] = fitFrame(dsImages[index], canvases[index], outputSize.x.int, outputSize.y.int)
        output.presentPixels(canvases[index])
    else:
      let
        output = screen.window(activeScreen)
        outputSize = output.framebufferSize
      canvases[activeScreen] = fitFrame(session.image, canvases[activeScreen], outputSize.x.int, outputSize.y.int)
      output.presentPixels(canvases[activeScreen])
    if session.av.timing.fps != fps:
      fps = session.av.timing.fps
      clock = newFrameClock(fps, getMonoTime().ticks)
    clock.advance(getMonoTime().ticks)
  echo "Frames: ", session.frames, "; video: ", session.videoFrames,
    "; audio frames: ", session.audioFrames

when isMainModule:
  main()
