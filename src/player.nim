import
  std/[monotimes, os, parseopt, posix, strutils, times],
  paddy, pixie, windy,
  retro/[anbernic, display, libretro, playeraudio, playerclock, playerds, playerinput,
    playerprofile, playervideo, playerworker, settings]

const
  SaveIntervalSeconds = 5
  PollIntervalMs = 2
  NanosecondsPerMillisecond = 1_000_000
  ExitHoldSeconds = 2
  Help = """Usage: mono-retro-player --core:PATH --rom:PATH --save-dir:DIR [--frames:N] [--mute] [--load-state:PATH]
Libretro player with Slappy audio. --mute opens no audio device.
--no-input requires --frames and feeds neutral controls for repeatable benchmarks.
--load-state:PATH is a startup-only CLI import of a core-defined format.
Desktop: drop a state file onto a window.
Arrows: D-pad. X/Z: A/B. A/S: L/R. PageUp/PageDown: L2/R2. Enter: Start. Backspace: Select.
Escape or window close exits. The first connected gamepad uses RetroPad positions.
DS: --ds-layout:combined|separate. EarthBound: --earthbound-ds. W/Q: X/Y.
Mouse or native touch: lower or Party screen. The two presets cannot be combined.
Native DS and EarthBound DS require two DRM outputs and separate screens.
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
    corePath, romPath, saveDirectory, statePath: string
    limit = 0'u64
    muted = false
    noInput = false
    dsLayout = NoDsLayout
    earthboundDs = false
    displayArguments = @["--device:auto"]
    parser = initOptParser(commandLineParams())
  for kind, key, value in parser.getopt():
    if kind != cmdLongOption: raise newException(ValueError, "Expected a player option")
    case key
    of "help": stdout.write(Help); return
    of "core": corePath = value
    of "rom": romPath = value
    of "save-dir": saveDirectory = value
    of "load-state":
      if value.len == 0: raise newException(IOError, "Missing state path")
      statePath = value
    of "mute": muted = true
    of "no-input": noInput = true
    of "ds-layout":
      if earthboundDs:
        raise newException(ValueError, "--earthbound-ds cannot be combined with --ds-layout")
      dsLayout = parseDsLayout(value)
    of "earthbound-ds":
      if dsLayout != NoDsLayout:
        raise newException(ValueError, "--earthbound-ds cannot be combined with --ds-layout")
      earthboundDs = true
    of "device", "display": displayArguments.add("--" & key & ":" & value)
    of "frames":
      limit = parseBiggestUInt(value)
      if limit == 0: raise newException(ValueError, "Frame limit must be positive")
    else: raise newException(ValueError, "Unknown player option: " & key)
  if corePath.len == 0 or romPath.len == 0 or saveDirectory.len == 0:
    raise newException(ValueError, Help)
  if noInput and limit == 0:
    raise newException(ValueError, "--no-input requires --frames")
  when defined(playerWalkBenchmark):
    if limit == 0: raise newException(ValueError, "Walking benchmark requires --frames")
    if noInput: raise newException(ValueError, "Walking benchmark cannot use --no-input")
  let dual = selectDualScreen(dsLayout, earthboundDs)
  var settings = parseSettings(displayArguments, detectDevice())
  let desktop = settings.displayBackend() == "x11"
  validateDsDisplay(dual.layout, settings.displayBackend(), settings.outputs.len)
  let session = openCoreWorker(corePath, romPath, saveDirectory, captureAudio = not muted,
    options = dual.options, statePath = statePath)
  defer: session.close()
  if dual.layout != NoDsLayout:
    validateDsFrame(session.av.geometry.baseWidth.int, session.av.geometry.baseHeight.int,
      dual.panelWidth, dual.panelHeight)
  settings.title = "mono-retro-player | " & session.libraryName & " | " &
    romPath.extractFilename & (if muted: " | MUTED" else: "")
  let
    windowTitles = case (if desktop: dual.layout else: NoDsLayout)
      of NoDsLayout: newSeq[string]()
      of CombinedDs: @[settings.title]
      of SeparateDs: @[settings.title & " | " & dual.topTitle,
        settings.title & " | " & dual.bottomTitle]
    initialSize = if dual.layout == SeparateDs:
        ivec2(int32(dual.panelWidth * dual.desktopScale),
          int32(dual.panelHeight * dual.desktopScale))
      else: ivec2(session.av.geometry.baseWidth.int32, session.av.geometry.baseHeight.int32)
    screen = openDisplay(settings,
      initialSize, windowTitles)
  defer: screen.close()
  validateDsDisplay(dual.layout, settings.displayBackend(), screen.count())
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
  echo "Core: ", session.libraryName, " ", session.libraryVersion
  echo "Save: ", session.savePath
  if statePath.len > 0: echo "State: ", statePath
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
    companionGesture: CompanionGesture
  when defined(playerTimings):
    var reusedScreens: array[2, int]
  proc installStateDrop(target: Window) =
    ## Import dropped opaque state onto this desktop window.
    target.onFileDrop = proc(fileName: string, fileData: string) =
      try:
        session.importStateData(fileData, fileName)
        if sound != nil: sound.reset()
        clock.reset(getMonoTime().ticks)
        lastSave = getMonoTime()
        stylus = DsStylus()
        companionGesture = CompanionGesture()
        target.focus()
      except CatchableError as error:
        stderr.writeLine("Rejected state " & fileName & ": " & error.msg)
  if desktop:
    for index in 0 ..< screen.count():
      installStateDrop(screen.window(index))
  when defined(playerTimings):
    resetTimings()
  when defined(playerTimings) or defined(playerWalkBenchmark):
    let loopStarted = getMonoTime()
  # Prime the pipeline before its first presentation deadline.
  session.prefetch(benchmarkButtons(0))
  clock.advance(getMonoTime().ticks)
  while not stopping and not session.shutdown and (limit == 0 or session.frames < limit):
    try:
      measured(Events):
        if not screen.poll(): break
    except IOError as error:
      # Windy reads dropped files before invoking the application's drop callback.
      if not desktop: raise
      stderr.writeLine("Could not read dropped state: " & error.msg)
      continue
    if sound != nil:
      measured(AudioOutput): sound.pump()
    var pads: seq[Gamepad]
    measured(Events): pads = pollGamepads()
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
    if not desktop and dual.layout == NoDsLayout and screen.count() > 1 and pad.buttonPressed(GamepadL2):
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
      measured(Saving): session.save()
      lastSave = now
    if (desktop and focusedIndex < 0) or size.x <= 0 or size.y <= 0:
      if not paused:
        session.pause()
        if sound != nil: sound.reset()
      paused = true
      clock.reset(now.ticks)
      sleep(PollIntervalMs)
      continue
    paused = false
    if now.ticks < clock.deadline:
      let remainingMs = int((clock.deadline - now.ticks) div NanosecondsPerMillisecond)
      measured(Waiting): sleep(min(PollIntervalMs, remainingMs))
      continue
    var held: set[Button]
    for (key, button) in KeyboardButtons:
      if window.buttonDown[key]: held.incl key
    var buttons = keyboardButtons(held) or gamepadButtons(pads)
    if not desktop and dual.layout == NoDsLayout and screen.count() > 1:
      buttons = buttons and not (1'u16 shl 12)
    var pointerInput = if dual.layout == SeparateDs and not desktop:
        nativeDsPointer(stylus, screen.touch.contacts, screen.width(1), screen.height(1),
          dual.panelWidth, dual.panelHeight)
      elif dual.layout != NoDsLayout:
        dsPointer(dual.layout, inputScreen, size.x.int, size.y.int,
          window.mousePos.x.int, window.mousePos.y.int, window.buttonDown[MouseLeft],
          dual.panelWidth, dual.panelHeight)
      else: PointerInput()
    if earthboundDs:
      let held = if desktop: inputScreen == 1 and window.buttonDown[MouseLeft]
        else: stylus.active
      pointerInput = companionGesture.companionPointer(pointerInput, held)
    when defined(playerWalkBenchmark):
      buttons = benchmarkButtons(session.frames)
      pointerInput = PointerInput()
    if noInput:
      buttons = 0
      pointerInput = PointerInput()
    session.step(buttons, pointerInput)
    # At most one core frame overlaps presentation. Controls are sampled again
    # on each main-loop iteration; the core and all its callbacks stay serialized.
    if not session.shutdown and (limit == 0 or session.frames < limit):
      when defined(playerWalkBenchmark): buttons = benchmarkButtons(session.frames)
      session.prefetch(buttons, pointerInput)
    if sound != nil:
      measured(AudioOutput): sound.submit(session.takeAudio(), session.av.timing.sampleRate)
    if dual.layout != NoDsLayout and session.image != nil:
      validateDsFrame(session.image.width, session.image.height, dual.panelWidth, dual.panelHeight)
    if dual.layout == SeparateDs and session.image != nil:
      for index in 0 .. 1:
        let
          output = screen.window(index)
          outputSize = output.framebufferSize
        if (desktop and output.minimized) or outputSize.x <= 0 or outputSize.y <= 0: continue
        var unchanged = false
        measured(ScreenSplit):
          # Native DRM retains scanout; desktop windows still redraw normally.
          unchanged = not desktop and canvases[index] != nil and
            canvases[index].width == outputSize.x.int and
            canvases[index].height == outputSize.y.int and
            sameDsScreen(session.image, dsImages[index], index, dual.panelWidth, dual.panelHeight)
          if not unchanged:
            dsImages[index] = dsScreen(session.image, dsImages[index], index,
              dual.panelWidth, dual.panelHeight)
        if unchanged:
          when defined(playerTimings): inc reusedScreens[index]
          continue
        measured(Scaling):
          canvases[index] = fitFrame(dsImages[index], canvases[index], outputSize.x.int, outputSize.y.int)
        measured(Presentation): output.presentPixels(canvases[index])
    else:
      let
        output = screen.window(activeScreen)
        outputSize = output.framebufferSize
      measured(Scaling):
        canvases[activeScreen] = fitFrame(session.image, canvases[activeScreen], outputSize.x.int, outputSize.y.int)
      measured(Presentation): output.presentPixels(canvases[activeScreen])
    if session.av.timing.fps != fps:
      fps = session.av.timing.fps
      clock = newFrameClock(fps, getMonoTime().ticks)
    clock.advance(getMonoTime().ticks)
  session.pause()
  echo "Frames: ", session.frames, "; video: ", session.videoFrames,
    "; audio frames: ", session.audioFrames
  if sound != nil:
    echo "Audio underruns: ", sound.underruns, "; overruns: ", sound.overruns
  printTimings(session.frames)
  when defined(playerTimings) or defined(playerWalkBenchmark):
    echo "Loop milliseconds: ", (getMonoTime() - loopStarted).inMilliseconds
  when defined(playerTimings):
    echo "Unchanged native screens: ", reusedScreens

when isMainModule:
  main()
