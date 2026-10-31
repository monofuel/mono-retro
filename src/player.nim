import
  std/[monotimes, os, parseopt, posix, strutils, times],
  paddy, pixie, windy,
  retro/[anbernic, display, gamepad, libretro, playeraudio, playerclock, playerds, playergpu,
    playerinput, playeroverlay, playerprofile, playervideo, playerworker, settings]

const
  SaveIntervalSeconds = 5
  PollIntervalMs = 2
  NanosecondsPerMillisecond = 1_000_000
  ExitHoldSeconds = 2
  AchievementIdleNs = 50_000_000'i64
  AchievementListNs = 250_000_000'i64
  ModalRedrawNs = 16_666_667'i64
  Help = """Usage: mono-retro-player --core:PATH --rom:PATH --save-dir:DIR [--frames:N] [--mute] [--load-state:PATH]
Libretro player with Slappy audio. --mute opens no audio device.
--video:auto|cpu|gpu selects native presentation; auto uses paired Panfrost outputs.
--no-input requires --frames and feeds neutral controls for repeatable benchmarks.
--load-state:PATH is a startup-only CLI import of a core-defined format.
Desktop: drop a state file onto a window.
Arrows: D-pad. X/Z: A/B. A/S: L/R. PageUp/PageDown: L2/R2. Enter: Start. Backspace: Select.
F1 or MENU/Home opens achievements; B/Escape returns. Escape outside the menu exits.
--achievements:on|off (default on); --ra-config:PATH overrides the private token file.
Sign in with mono-retro-ra login. Only Casual achievements are supported.
The first connected gamepad uses RetroPad positions.
DS: --ds-layout:combined|separate. EarthBound: --earthbound-ds
  [--earthbound-viewport:WIDTHxHEIGHT] [--earthbound-scale:auto|N]. W/Q: X/Y.
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
    videoMode = AutoVideo
    noInput = false
    dsLayout = NoDsLayout
    earthboundDs = false
    viewportWidth = EarthboundWidth
    viewportHeight = EarthboundHeight
    gameScale = 0
    earthboundOptions = false
    achievementsEnabled = true
    raConfigPath: string
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
    of "video": videoMode = parseVideoMode(value)
    of "no-input": noInput = true
    of "ra-config":
      if value.len == 0: raise newException(ValueError, "Missing achievement config path")
      raConfigPath = value
    of "achievements":
      case value
      of "on": achievementsEnabled = true
      of "off": achievementsEnabled = false
      else: raise newException(ValueError, "Expected --achievements:on|off")
    of "ds-layout":
      if earthboundDs:
        raise newException(ValueError, "--earthbound-ds cannot be combined with --ds-layout")
      dsLayout = parseDsLayout(value)
    of "earthbound-ds":
      if value.len > 0: raise newException(ValueError, "--earthbound-ds takes no value")
      if dsLayout != NoDsLayout:
        raise newException(ValueError, "--earthbound-ds cannot be combined with --ds-layout")
      earthboundDs = true
    of "earthbound-viewport":
      let viewport = parseEarthboundViewport(value)
      viewportWidth = viewport.width
      viewportHeight = viewport.height
      earthboundOptions = true
    of "earthbound-scale":
      let scale = parseEarthboundScale(value)
      gameScale = if scale.autoScale: 0 else: scale.scale
      earthboundOptions = true
    of "device", "display": displayArguments.add("--" & key & ":" & value)
    of "frames":
      limit = parseBiggestUInt(value)
      if limit == 0: raise newException(ValueError, "Frame limit must be positive")
    else: raise newException(ValueError, "Unknown player option: " & key)
  if earthboundOptions and not earthboundDs:
    raise newException(ValueError, "--earthbound-viewport and --earthbound-scale require --earthbound-ds")
  if corePath.len == 0 or romPath.len == 0 or saveDirectory.len == 0:
    raise newException(ValueError, Help)
  if noInput and limit == 0:
    raise newException(ValueError, "--no-input requires --frames")
  when defined(playerWalkBenchmark):
    if limit == 0: raise newException(ValueError, "Walking benchmark requires --frames")
    if noInput: raise newException(ValueError, "Walking benchmark cannot use --no-input")
  let dual = selectDualScreen(dsLayout, earthboundDs, viewportWidth, viewportHeight)
  var settings = parseSettings(displayArguments, detectDevice())
  let desktop = settings.displayBackend() == "x11"
  validateDsDisplay(dual.layout, settings.displayBackend(), settings.outputs.len)
  let session = openCoreWorker(corePath, romPath, saveDirectory, captureAudio = not muted,
    options = dual.options, statePath = statePath,
    raConfigPath = raConfigPath, achievementsEnabled = achievementsEnabled)
  defer: session.close()
  if dual.layout != NoDsLayout:
    validateDualGeometry(session.av.geometry.baseWidth.int, session.av.geometry.baseHeight.int, dual.geometry)
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
    windowSizes = if desktop and earthboundDs:
        let sizes = desktopWindowSizes(dual.geometry.game, dual.geometry.companion,
          if gameScale > 0: gameScale else: EarthboundDesktopScale, EarthboundDesktopScale)
        @[ivec2(sizes[0].width.int32, sizes[0].height.int32),
          ivec2(sizes[1].width.int32, sizes[1].height.int32)]
      else: newSeq[IVec2]()
    screen = openDisplay(settings,
      initialSize, windowTitles, vsync = settings.displayBackend() == "drm",
      windowSizes = windowSizes)
  defer: screen.close()
  validateDsDisplay(dual.layout, settings.displayBackend(), screen.count())
  if earthboundDs and gameScale > 0 and videoMode == GpuVideo:
    raise newException(ValueError, "Explicit EarthBound scale requires CPU video")
  let gpu = openPlayerGpu(if earthboundDs and gameScale > 0: CpuVideo else: videoMode,
    screen, settings)
  defer: gpu.close()
  var
    activeScreen = screen.count() - 1
    black: seq[Image]
    blanked = newSeq[bool](screen.count())
  if gpu == nil:
    for index in 0 ..< screen.count():
      let image = newImage(screen.width(index), screen.height(index))
      image.fill(rgbx(0, 0, 0, 255))
      black.add(image)
      screen.window(index).presentPixels(image)
      blanked[index] = true
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
  echo "Presentation: ", (if gpu == nil: "CPU" else: "GPU paired atomic")
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
    overlay = newOverlayState()
    composition: OverlayComposition
    lastAchievementIdle, lastAchievementList: int64
    lastModalPresentation: int64
    pointerHeld, suppressPointer: bool
    suppressButtons, overlayInputArmed: bool
    toggleHeld, activateHeld, backHeld: bool
    pointerX, pointerY: float32
    pointerOutput: int
  when defined(playerTimings):
    var reusedScreens: array[2, int]
  let overlayDisplay = if dual.layout == SeparateDs or (not desktop and screen.count() > 1):
      OverlaySeparate
    elif dual.layout == CombinedDs: OverlayCombined
    else: OverlaySingle
  proc collectAchievements() =
    ## Copy worker-owned metadata and consume each notice exactly once.
    overlay.setSnapshot(session.raSnapshot)
    overlay.enqueueNotices(session.takeRaNotices())
  proc presentOverlay() =
    ## Compose optional UI without writing into worker-owned core frames.
    composition = overlay.composeOverlay(session.image, session.videoFrames,
      overlayDisplay, dual.layout != NoDsLayout, dual.panelWidth,
      dual.panelHeight, activeScreen, session.imageChanged and not overlay.isOpen, dual.geometry)
    let
      modalNow = if desktop and composition.modal: getMonoTime().ticks else: 0'i64
      refreshModal = desktop and composition.modal and
        modalNow - lastModalPresentation >= ModalRedrawNs
    if gpu != nil:
      measured(Presentation):
        gpu.presentComposition(composition.sourceImage, composition.crops,
          composition.revision, composition.changed)
    elif not composition.modal and dual.layout == SeparateDs and composition.sourceImage != nil:
      for index in 0 .. 1:
        let
          output = screen.window(index)
          size = output.framebufferSize
        if (desktop and output.minimized) or size.x <= 0 or size.y <= 0: continue
        var unchanged = false
        measured(ScreenSplit):
          unchanged = not desktop and canvases[index] != nil and
            canvases[index].width == size.x.int and canvases[index].height == size.y.int and
            sameDsScreen(composition.sourceImage, dsImages[index], index,
              dual.geometry)
          if not unchanged:
            dsImages[index] = dsScreen(composition.sourceImage, dsImages[index], index,
              dual.geometry)
        if unchanged:
          when defined(playerTimings): inc reusedScreens[index]
          continue
        measured(Scaling):
          canvases[index] = fitFrame(dsImages[index], canvases[index], size.x.int, size.y.int,
            if earthboundDs and index == 0: gameScale else: 0)
        measured(Presentation): output.presentPixels(canvases[index])
        blanked[index] = false
    else:
      for index in 0 ..< screen.count():
        let
          output = screen.window(index)
          size = output.framebufferSize
          crop = composition.crops[index]
        if size.x <= 0 or size.y <= 0 or (desktop and output.minimized): continue
        if crop.width == 0 or crop.height == 0:
          if black[index].width != size.x.int or black[index].height != size.y.int:
            black[index] = newImage(size.x.int, size.y.int)
            black[index].fill(rgbx(0, 0, 0, 255))
            blanked[index] = false
          if not blanked[index]:
            measured(Presentation): output.presentPixels(black[index])
            blanked[index] = true
          continue
        let redraw = composition.changed or canvases[index] == nil or
          canvases[index].width != size.x.int or canvases[index].height != size.y.int
        if not redraw and not refreshModal and not (desktop and not composition.modal): continue
        if redraw or (desktop and not composition.modal):
          measured(Scaling):
            canvases[index] = composition.fitComposition(index, size.x.int, size.y.int, canvases[index],
              if earthboundDs and index == 0: gameScale else: 0)
        measured(Presentation): output.presentPixels(canvases[index])
        blanked[index] = false
      if desktop and composition.modal and (composition.changed or refreshModal):
        lastModalPresentation = modalNow
  proc overlayTransition(action: OverlayAction) =
    ## Quiesce prefetched work before opening and discard modal input on return.
    if action in {OverlayOpened, OverlayClosed}:
      session.pause()
      if sound != nil: sound.reset()
      clock.reset(getMonoTime().ticks)
      stylus = DsStylus()
      companionGesture = CompanionGesture()
      suppressPointer = true
      suppressButtons = true
      overlayInputArmed = false
      dsImages = default(array[2, Image])
      session.idleAchievements(withList = action == OverlayOpened)
      lastAchievementIdle = getMonoTime().ticks
      if action == OverlayOpened: lastAchievementList = lastAchievementIdle
      collectAchievements()
  proc installStateDrop(target: Window) =
    ## Import dropped opaque state onto this desktop window.
    target.onFileDrop = proc(fileName: string, fileData: string) =
      try:
        session.importStateData(fileData, fileName)
        if overlay.isOpen:
          overlayTransition(overlay.handleOverlay(OverlayToggle))
        if sound != nil: sound.reset()
        clock.reset(getMonoTime().ticks)
        lastSave = getMonoTime()
        stylus = DsStylus()
        companionGesture = CompanionGesture()
        suppressPointer = true
        suppressButtons = true
        overlayInputArmed = false
        pointerHeld = false
        dsImages = default(array[2, Image])
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
  when defined(playerTimings):
    let
      loopCpuStarted = cpuTime()
      loopProcessCpuStarted = processCpuTime()
  # Prime the pipeline before its first presentation deadline.
  session.prefetch(benchmarkButtons(0))
  clock.advance(getMonoTime().ticks)
  while not stopping and not session.shutdown and (limit == 0 or session.frames < limit):
    try:
      measured(Events):
        if not screen.poll(escapeCloses = false): break
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
    if not noInput and not suppressButtons and not overlay.isOpen and not desktop and
        dual.layout == NoDsLayout and screen.count() > 1 and pad.buttonPressed(GamepadL2):
      if gpu == nil:
        screen.window(activeScreen).presentPixels(black[activeScreen])
        blanked[activeScreen] = true
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
    var held: set[Button]
    for (key, button) in KeyboardButtons:
      if window.buttonDown[key]: held.incl key
    let gameButtons = keyboardButtons(held) or gamepadButtons(pads)
    var controlsHeld = gamepadButtons(pads) != 0 or pad.button(GamepadHome)
    for index in 0 ..< screen.count():
      let target = screen.window(index)
      controlsHeld = controlsHeld or target.buttonDown[KeyF1] or target.buttonDown[KeyEscape]
      for (key, button) in KeyboardButtons:
        controlsHeld = controlsHeld or target.buttonDown[key]
    if not controlsHeld:
      suppressButtons = false
      overlayInputArmed = true
    let
      activateButton = physicalButton(pad.name, "A")
      backButton = physicalButton(pad.name, "B")
      togglePressed = (window.buttonPressed[KeyF1] or pad.buttonPressed(GamepadHome)) and not toggleHeld
      activatePressed = (window.buttonPressed[KeyEnter] or pad.buttonPressed(activateButton)) and not activateHeld
      backPressed = (window.buttonPressed[KeyEscape] or pad.buttonPressed(backButton)) and not backHeld
    toggleHeld = window.buttonDown[KeyF1] or pad.button(GamepadHome)
    activateHeld = window.buttonDown[KeyEnter] or pad.button(activateButton)
    backHeld = window.buttonDown[KeyEscape] or pad.button(backButton)
    if window.buttonPressed[KeyEscape] and not overlay.isOpen and
        (not suppressButtons or noInput):
      break
    if not noInput:
      if togglePressed:
        overlayTransition(overlay.handleOverlay(OverlayToggle))
      elif overlay.isOpen and overlayInputArmed:
        for (pressed, command) in [
          (backPressed, OverlayBack),
          (activatePressed, OverlayActivate),
          (window.buttonPressed[KeyUp] or pad.buttonPressed(GamepadUp), OverlayPrevious),
          (window.buttonPressed[KeyDown] or pad.buttonPressed(GamepadDown), OverlayNext),
          (window.buttonPressed[KeyLeft] or pad.buttonPressed(GamepadLeft), OverlayPagePrevious),
          (window.buttonPressed[KeyRight] or pad.buttonPressed(GamepadRight), OverlayPageNext)]:
          if pressed:
            overlayTransition(overlay.handleOverlay(command))
            break
    let
      contact = overlayContact(window, desktop, inputScreen, screen.touch.contacts)
      contactHeld = contact.held
      contactX = contact.x
      contactY = contact.y
      contactOutput = contact.output
    if overlay.isOpen and not noInput:
      if contactHeld:
        pointerX = contactX
        pointerY = contactY
        pointerOutput = contactOutput
      elif pointerHeld and not suppressPointer:
        let point = composition.overlayPointer(pointerOutput, screen.width(pointerOutput),
          screen.height(pointerOutput), pointerX, pointerY)
        if point.inside: overlayTransition(overlay.pointerOverlay(point.x, point.y))
    pointerHeld = contactHeld
    if not contactHeld: suppressPointer = false
    collectAchievements()
    overlay.updateOverlay(now.ticks)
    if now.ticks - lastAchievementIdle >= AchievementIdleNs and
        (overlay.isOpen or paused or (desktop and focusedIndex < 0)):
      let withList = overlay.isOpen and now.ticks - lastAchievementList >= AchievementListNs
      session.idleAchievements(withList)
      lastAchievementIdle = now.ticks
      if withList: lastAchievementList = now.ticks
      collectAchievements()
    if overlay.isOpen:
      presentOverlay()
      clock.reset(now.ticks)
      sleep(PollIntervalMs)
      continue
    if (now - lastSave).inSeconds >= SaveIntervalSeconds:
      measured(Saving): session.save()
      lastSave = now
    if (desktop and focusedIndex < 0) or size.x <= 0 or size.y <= 0:
      if not paused:
        session.pause()
        if sound != nil: sound.reset()
        suppressButtons = true
        suppressPointer = true
        stylus = DsStylus()
        companionGesture = CompanionGesture()
        collectAchievements()
      paused = true
      clock.reset(now.ticks)
      sleep(PollIntervalMs)
      continue
    paused = false
    if now.ticks < clock.deadline:
      let remainingMs = int((clock.deadline - now.ticks) div NanosecondsPerMillisecond)
      measured(Waiting): sleep(min(PollIntervalMs, remainingMs))
      continue
    var buttons = if suppressButtons: 0'u16 else: gameButtons
    if not desktop and dual.layout == NoDsLayout and screen.count() > 1:
      buttons = buttons and not (1'u16 shl 12)
    var pointerInput = if dual.layout == SeparateDs and not desktop:
        nativeDsPointer(stylus, screen.touch.contacts, screen.width(1), screen.height(1),
          dual.geometry)
      elif dual.layout != NoDsLayout:
        dsPointer(dual.layout, inputScreen, size.x.int, size.y.int,
          window.mousePos.x.int, window.mousePos.y.int, window.buttonDown[MouseLeft],
          dual.geometry)
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
    if suppressPointer: pointerInput = PointerInput()
    session.step(buttons, pointerInput, compareVideo = gpu != nil)
    # At most one core frame overlaps presentation. Controls are sampled again
    # on each main-loop iteration; the core and all its callbacks stay serialized.
    if not session.shutdown and (limit == 0 or session.frames < limit):
      when defined(playerWalkBenchmark): buttons = benchmarkButtons(session.frames)
      session.prefetch(buttons, pointerInput)
    if sound != nil:
      measured(AudioOutput): sound.submit(session.takeAudio(), session.av.timing.sampleRate)
    if dual.layout != NoDsLayout and session.image != nil:
      validateDualGeometry(session.image.width, session.image.height, dual.geometry)
    collectAchievements()
    overlay.updateOverlay(getMonoTime().ticks)
    presentOverlay()
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
    echo "Loop main-thread CPU milliseconds: ", (cpuTime() - loopCpuStarted) * 1000
    echo "Loop process CPU milliseconds: ", (processCpuTime() - loopProcessCpuStarted) * 1000
    echo "Unchanged native screens: ", reusedScreens

when isMainModule:
  main()
