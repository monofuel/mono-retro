import
  std/[json, monotimes, os, osproc, tempfiles, times],
  paddy, pixie, windy,
  ./[anbernic, display, gamepad, gamelibrary, input, launcherui, libraryview,
    menu, powercontrol, settings, systeminfo, systemvolume,
    testerprocess, volumeui]

type
  LibraryInput = enum
    MoveUp, MoveDown, MoveLeft, MoveRight, OpenGame, GoBack, OpenTools,
    Favourite, Details, PreviousFilter, NextFilter

const
  PollIntervalMs = 8
  PowerIntervalMs = 2000
  StickThreshold = 0.6'f32

proc runLibrary*(root, configPath: string, displayArguments: seq[string],
    duration: int, stopping: proc(): bool) =
  ## Supervise a portable library while releasing all hardware during gameplay.
  let
    paths = libraryPaths(root, configPath)
    config = loadConfig(paths.config)
    settings = parseSettings(displayArguments, detectDevice())
    desktop = settings.displayBackend() == "x11"
    ui = newLibraryUi()
    helper = getAppDir() / "mono-retro-library"
    jobDirectory = createTempDir("mono-retro-library-", "")
    progressPath = jobDirectory / "progress.json"
    started = getMonoTime()
  createDir(jobDirectory)
  setFilePermissions(jobDirectory, {fpUserRead, fpUserWrite, fpUserExec})
  var
    state: LibraryViewState
    index: LibraryIndex
    screen: Display
    volume: SystemVolume
    volumeUi = newVolumeUi()
    volumeImage: Image
    volumeVisible = false
    backInputs: seq[InputDevice]
    power = readPower(settings.batterySupply, currentSupply = settings.batteryCurrentSupply)
    lastPower = getMonoTime()
    transitionStarted = getMonoTime()
    dirty = true
    armed = false
    navigationHeld = -1
    navigationRepeat = getMonoTime()
    mouseHeld = false
    pointerStart: Vec2
    pointerLast: Vec2
    pointerId = -1'i32
    pointerDragged = false
    pointerScreen = -1
    pending: seq[LibraryInput]
    job: Process
    jobKind: string
    pendingGame, offlineGame: string
    syncAfterScan = fileExists(paths.credentials)
    quit = false
    sizes: seq[IVec2]

  proc closeScreens() =
    ## Release gamepads, touch, volume and display handles before a child starts.
    volume.close()
    volume = nil
    closeGamepads()
    for device in backInputs: device.close()
    backInputs.setLen(0)
    if screen != nil: screen.close()
    screen = nil

  proc cancelJob() =
    ## Stop the owned library worker before handing CPU and storage to a game.
    if job != nil:
      if job.running(): job.terminate()
      if job.waitForExit(3000) == -1:
        job.kill()
        discard job.waitForExit()
      job.close()
      job = nil
    state.busy = false

  defer:
    cancelJob()
    closeScreens()
    if fileExists(progressPath): removeFile(progressPath)
    removeDir(jobDirectory)

  proc startJob(command: string, extra: seq[string] = @[]) =
    ## Delegate network and scan work to the same CLI available to humans.
    if job != nil: raise newException(IOError, "Library operation is already running")
    if fileExists(progressPath): removeFile(progressPath)
    job = startProcess(helper, args = @[command, "--library:" & paths.root,
      "--config:" & paths.config, "--progress:" & progressPath,
      "--name:" & settings.title] & extra, options = {poParentStreams})
    jobKind = command
    state.busy = true
    state.error = false
    state.message = "Working…"
    dirty = true

  proc reload() =
    ## Read a complete snapshot only after a writer has published it.
    paths.requireStorage(config)
    index = paths.loadIndex()
    ui.clearCovers()
    state.filter = clamp(state.filter, 0, index.filters().high)
    state.selected = clamp(state.selected, 0, max(0, index.visibleGames(state.filter).high))

  proc pointer(phase: TouchPhase, point: Vec2, screenIndex: int, id = 0'i32) =
    ## Select covers on tap and require a separate Play action to launch.
    if screen.count() > 1 and screenIndex == 0: return
    if phase == TouchBegin:
      if pointerId != -1: return
      pointerId = id
      pointerStart = point
      pointerLast = point
      pointerDragged = false
      pointerScreen = screenIndex
    elif phase == TouchMove and pointerScreen == screenIndex and pointerId == id:
      if abs(point.y - pointerStart.y) > 24: pointerDragged = true
      if pointerDragged and abs(point.y - pointerLast.y) > 45:
        let direction = if point.y > pointerLast.y: -1 else: 1
        case state.page
        of GamesPage:
          let count = index.visibleGames(state.filter).len
          let columns = libraryLayout(screen.width(screenIndex), screen.height(screenIndex), state.selected, count).columns
          state.selected = clamp(state.selected + direction * columns, 0, max(0, count - 1))
        of ToolsPage: state.tool = clamp(state.tool + direction, 0, ToolLabels.high)
        of CollectionsPage: state.collection = clamp(state.collection + direction, 0, max(0, index.collections.high))
        of SystemPage: state.scroll = max(0, state.scroll + direction)
        else: discard
        pointerLast = point
        dirty = true
    elif phase in {TouchEnd, TouchCancel} and pointerScreen == screenIndex and pointerId == id:
      pointerId = -1
      pointerScreen = -1
      if phase == TouchCancel or pointerDragged or abs(point.y - pointerStart.y) > 20: return
      let layout = libraryLayout(screen.width(screenIndex), screen.height(screenIndex),
        state.selected, index.visibleGames(state.filter).len)
      if state.page == GamesPage:
        for position, area in layout.cards:
          if area.contains(point):
            state.selected = layout.first + position
            dirty = true
        if layout.play.contains(point): pending.add OpenGame
        if layout.tools.contains(point): pending.add OpenTools
        if layout.previous.contains(point): pending.add PreviousFilter
        if layout.next.contains(point): pending.add NextFilter
      elif state.page in {ToolsPage, CollectionsPage}:
        let
          selected = if state.page == ToolsPage: state.tool else: state.collection
          rows = max(1, (screen.height(screenIndex) - 150) div 43)
          first = max(0, selected - rows + 1)
          row = int(point.y - 115) div 43 + first
          count = if state.page == ToolsPage: ToolLabels.len else: index.collections.len
        if point.y >= 115 and row in 0 ..< count:
          if state.page == ToolsPage: state.tool = row else: state.collection = row
          pending.add OpenGame
      elif state.page == GamePage: pending.add OpenGame
      elif state.page in {PowerPage, ConflictPage}:
        state.confirmYes = point.x > screen.width(screenIndex).float32 / 2
        pending.add OpenGame
      dirty = true

  proc openScreens() =
    ## Restore the correct single or paired display configuration after a game.
    screen = openDisplay(settings)
    volume = openSystemVolume(settings)
    sizes.setLen(0)
    for screenIndex in 0 ..< screen.count():
      sizes.add screen.window(screenIndex).framebufferSize
      let target = screenIndex
      screen.window(screenIndex).onTouch = proc(event: TouchEvent) =
        pointer(event.phase, event.contact.position, target, event.contact.id)
    if not desktop:
      for binding in settings.bindings:
        if binding.label == "BACK":
          for path in inputPaths(@[binding.device]): backInputs.add openInput(path)
    initGamepads()
    pending.setLen(0)
    armed = false
    mouseHeld = false
    pointerId = -1
    dirty = true

  proc play(hash: string) =
    ## Validate mounted content and use the player's orderly save/exit lifecycle.
    var lock = paths.lockLibrary(config)
    defer: lock.close()
    var game: LibraryGame
    for candidate in index.games:
      if candidate.hash == hash: game = candidate; break
    if game == nil: raise newException(IOError, "Game is no longer in the library")
    let arguments = paths.gameArguments(config, game)
    if not fileExists(config.playerPath): raise newException(IOError, "Player is not installed")
    closeScreens()
    try:
      let code = runTester(config.playerPath, arguments, stopping)
      state.message = if code == 0: "" else: "Game exited with code " & $code
      state.error = code != 0
    finally:
      if not stopping(): openScreens()
    if stopping(): return
    game.lastPlayed = getTime().toUnix
    paths.saveIndex(index)
    lock.close()
    if fileExists(paths.credentials): startJob("sync")

  openScreens()
  try:
    reload()
    startJob("scan")
  except CatchableError as error:
    state.message = error.msg
    state.error = true

  while not quit and not stopping() and
      (duration == 0 or (getMonoTime() - started).inSeconds < duration):
    if not screen.poll(escapeCloses = false): break
    if job != nil:
      if fileExists(progressPath):
        let progress = parseFile(progressPath)
        let message = progress.stringField("message")
        if message != state.message: state.message = message; dirty = true
      if not job.running():
        let code = job.waitForExit()
        job.close()
        job = nil
        state.busy = false
        state.error = code != 0
        if code != 0 and (not fileExists(progressPath) or
            not parseFile(progressPath).hasKey("error")):
          state.message = "Library operation failed (code " & $code & "); see the launcher log"
        try:
          reload()
          if pendingGame.len > 0:
            let hash = pendingGame
            pendingGame = ""
            if code == 0: play(hash)
            else:
              offlineGame = hash
              state.message &= " · Play again to use your local save"
          elif jobKind == "scan" and syncAfterScan:
            syncAfterScan = false
            startJob("sync")
          elif code == 0 and jobKind in ["pair", "select"]:
            if jobKind == "pair": state.page = CollectionsPage
            startJob("sync")
        except CatchableError as error:
          state.message = error.msg
          state.error = true
        dirty = true
        state.transition = 0
        transitionStarted = getMonoTime()
    if volume != nil:
      let nowNs = getMonoTime().ticks
      let changed = volume.poll(nowNs)
      let visible = volume.visible(nowNs)
      if changed or volumeImage == nil:
        volumeImage = volumeUi.renderVolume(volume.percent, volume.error, 320, volumeImage)
      if changed or visible != volumeVisible: dirty = true
      volumeVisible = visible
    var activationHeld = false
    var directionHeld = -1
    for raw in pollGamepads():
      let pad = raw.mapAnbernic()
      let activate = physicalButton(pad.name, "A")
      activationHeld = activationHeld or pad.button(activate) or pad.button(GamepadStart)
      for (button, direction) in [(GamepadUp, MoveUp), (GamepadDown, MoveDown),
          (GamepadLeft, MoveLeft), (GamepadRight, MoveRight)]:
        if pad.button(button): directionHeld = ord(direction)
      if pad.buttonPressed(activate): pending.add OpenGame
      if pad.buttonPressed(physicalButton(pad.name, "B")): pending.add GoBack
      if pad.buttonPressed(physicalButton(pad.name, "X")): pending.add Details
      if pad.buttonPressed(physicalButton(pad.name, "Y")): pending.add Favourite
      if pad.buttonPressed(GamepadStart): pending.add OpenTools
      if pad.buttonPressed(GamepadL1): pending.add PreviousFilter
      if pad.buttonPressed(GamepadR1): pending.add NextFilter
      let
        stickX = pad.axis(GamepadLStickX)
        stickY = pad.axis(GamepadLStickY)
      if directionHeld < 0:
        if abs(stickX) >= StickThreshold and abs(stickX) > abs(stickY):
          directionHeld = ord(if stickX > 0: MoveRight else: MoveLeft)
        elif abs(stickY) >= StickThreshold:
          directionHeld = ord(if stickY > 0: MoveUp else: MoveDown)
    if directionHeld >= 0:
      if directionHeld != navigationHeld:
        pending.add LibraryInput(directionHeld)
        navigationRepeat = getMonoTime() + initDuration(milliseconds = 350)
      elif getMonoTime() >= navigationRepeat:
        pending.add LibraryInput(directionHeld)
        navigationRepeat = getMonoTime() + initDuration(milliseconds = 110)
    navigationHeld = directionHeld
    for device in backInputs:
      for event in device.readEvents():
        if event.kind == EventKey and event.code == 158 and event.value == 1: pending.add GoBack
    if desktop:
      for screenIndex in 0 ..< screen.count():
        let window = screen.window(screenIndex)
        activationHeld = activationHeld or window.buttonDown[KeyEnter] or window.buttonDown[MouseLeft]
        for (key, action) in [(KeyUp, MoveUp), (KeyDown, MoveDown), (KeyLeft, MoveLeft),
            (KeyRight, MoveRight), (KeyEnter, OpenGame), (KeyEscape, GoBack),
            (KeyX, Details), (KeyY, Favourite), (KeyTab, OpenTools),
            (KeyQ, PreviousFilter), (KeyE, NextFilter)]:
          if window.buttonPressed[key]: pending.add action
        if window.buttonPressed[MouseLeft]:
          pointer(TouchBegin, window.mousePos.vec2, screenIndex)
          mouseHeld = true
        if mouseHeld: pointer(TouchMove, window.mousePos.vec2, screenIndex)
        if mouseHeld and window.buttonReleased[MouseLeft]:
          pointer(TouchEnd, window.mousePos.vec2, screenIndex)
          mouseHeld = false
        if window.scrollDelta.y != 0:
          pending.add (if window.scrollDelta.y > 0: MoveUp else: MoveDown)
    if not activationHeld: armed = true
    for action in pending:
      try:
        if action == GoBack:
          let cancelling = job != nil
          if job != nil:
            cancelJob()
            pendingGame = ""
            state.message = "Cancelled; local files are preserved"
          if state.page != GamesPage: state.page = GamesPage
          elif desktop and not cancelling: quit = true
        elif action == OpenTools: state.page = ToolsPage
        elif action in {PreviousFilter, NextFilter}:
          let count = index.filters().len
          state.filter = (state.filter + count + (if action == NextFilter: 1 else: -1)) mod count
          state.selected = 0
        elif action in {MoveUp, MoveDown, MoveLeft, MoveRight}:
          let direction = if action in {MoveUp, MoveLeft}: -1 else: 1
          case state.page
          of GamesPage:
            let count = index.visibleGames(state.filter).len
            let columns = libraryLayout(screen.width(screen.count() - 1), screen.height(screen.count() - 1), state.selected, count).columns
            state.selected = clamp(state.selected + direction * (if action in {MoveUp, MoveDown}: columns else: 1), 0, max(0, count - 1))
          of ToolsPage: state.tool = clamp(state.tool + direction, 0, ToolLabels.high)
          of CollectionsPage: state.collection = clamp(state.collection + direction, 0, max(0, index.collections.high))
          of SystemPage: state.scroll = max(0, state.scroll + direction)
          of PowerPage, ConflictPage: state.confirmYes = direction > 0
          else: discard
        elif not armed or state.busy: discard
        elif action == Favourite:
          let games = index.visibleGames(state.filter)
          if games.len > 0: startJob("favourite", @["--game:" & games[state.selected].hash])
        elif action == Details: state.page = GamePage
        elif action == OpenGame:
          armed = false
          case state.page
          of GamesPage, GamePage:
            let games = index.visibleGames(state.filter)
            if games.len > 0:
              let hash = games[state.selected].hash
              if games[state.selected].saveConflict:
                state.page = ConflictPage
                state.confirmYes = false
              elif fileExists(paths.credentials) and offlineGame != hash:
                pendingGame = hash
                startJob("sync-saves", @["--game:" & hash])
              else:
                offlineGame = ""
                play(hash)
          of ToolsPage:
            case state.tool
            of 0:
              closeScreens()
              try:
                discard runTester(getAppDir() / "mono-retro-hwtest", @["test", "--seconds:3600"] & displayArguments, stopping)
              finally:
                if not stopping(): openScreens()
            of 1: state.page = SystemPage
            of 2:
              state.page = CollectionsPage
              startJob("collections")
            of 3:
              state.page = PairPage
              startJob("pair")
            of 4: startJob("sync")
            of 5: startJob("disconnect")
            of 6, 7:
              state.reboot = state.tool == 6
              state.page = PowerPage
              state.confirmYes = false
            of 8:
              syncAfterScan = false
              startJob("scan")
            else: discard
          of CollectionsPage:
            if index.collections.len > 0:
              startJob("select", @["--id:" & $index.collections[state.collection].id])
          of PowerPage:
            if state.confirmYes:
              let reason = power.powerBlockReason()
              if reason.len > 0: raise newException(IOError, reason)
              var request = requestPower(if state.reboot: RebootSystem else: ShutdownSystem)
              try:
                discard request.waitForExit()
                checkPowerRequest(request, if state.reboot: RebootSystem else: ShutdownSystem)
              finally:
                if request != nil: request.close()
              state.message = "Power request accepted"
            state.page = GamesPage
          of ConflictPage:
            let games = index.visibleGames(state.filter)
            if games.len > 0:
              pendingGame = games[state.selected].hash
              startJob("resolve", @["--game:" & pendingGame,
                "--choice:" & (if state.confirmYes: "server" else: "local")])
              state.page = GamesPage
          else: discard
        dirty = true
        state.transition = 0
        transitionStarted = getMonoTime()
      except CatchableError as error:
        state.message = error.msg
        state.error = true
        dirty = true
    pending.setLen(0)
    if stopping() or screen == nil: break
    if (getMonoTime() - lastPower).inMilliseconds >= PowerIntervalMs:
      let updated = readPower(settings.batterySupply, currentSupply = settings.batteryCurrentSupply)
      if power != updated: power = updated; dirty = true
      lastPower = getMonoTime()
    for screenIndex in 0 ..< screen.count():
      if sizes[screenIndex] != screen.window(screenIndex).framebufferSize:
        sizes[screenIndex] = screen.window(screenIndex).framebufferSize
        dirty = true
    if state.transition < 1:
      state.transition = min(1'f32, (getMonoTime() - transitionStarted).inMilliseconds.float32 / 140)
      dirty = true
    if dirty:
      let lines = localSystem() & power.powerLines() & localNetwork()
      for screenIndex in 0 ..< screen.count():
        let image = ui.renderLibrary(paths, index, state, power, screen.width(screenIndex),
          screen.height(screenIndex), screen.count() > 1 and screenIndex == 0, lines)
        if volumeVisible and screenIndex == screen.count() - 1 and volumeImage != nil:
          image.draw(volumeImage, translate(vec2(((image.width - volumeImage.width) div 2).float32, 12)))
        screen.present(image, screenIndex)
      dirty = false
    sleep(PollIntervalMs)
