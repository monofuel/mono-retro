import
  std/[json, monotimes, os, osproc, tempfiles, times],
  paddy, pixie, windy,
  ./[anbernic, display, gamepad, gamelibrary, input, libraryview,
    menu, menuthemes, powercontrol, settings, systeminfo, systemvolume,
    testerprocess, volumeui]

type
  LibraryInput = enum
    MoveUp, MoveDown, MoveLeft, MoveRight, OpenGame, GoBack, OpenTools,
    Favourite, Details, PreviousFilter, NextFilter, ActivateTarget

const
  PollIntervalMs = 8
  PowerIntervalMs = 2000
  StickThreshold = 0.6'f32
  StartupNetworkWaitSeconds = 60
  NetworkProbeIntervalMs = 3000

proc runLibrary*(root, configPath: string, displayArguments: seq[string],
    duration: int, stopping: proc(): bool, themeOverride = "") =
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
    preferencesPath = themePreferencesPath()
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
    pendingTargets: seq[ViewTarget]
    job: Process
    jobKind: string
    pendingGame, offlineGame: string
    syncAfterScan = fileExists(paths.credentials)
    waitingForNetwork = false
    networkProbeAt = started
    networkDeadline = started + initDuration(seconds = StartupNetworkWaitSeconds)
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
        state.moveSelection(index, screen.width(screenIndex), screen.height(screenIndex), direction, true)
        pointerLast = point
        dirty = true
    elif phase in {TouchEnd, TouchCancel} and pointerScreen == screenIndex and pointerId == id:
      pointerId = -1
      pointerScreen = -1
      if phase == TouchCancel or pointerDragged or abs(point.y - pointerStart.y) > 20: return
      let item = state.pageLayout(index, screen.width(screenIndex), screen.height(screenIndex)).hitTarget(point)
      if item.action != NoViewAction:
        pendingTargets.add item
        pending.add ActivateTarget
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
    pendingTargets.setLen(0)
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

  proc activate(item: ViewTarget) =
    ## Keep application operations shared across every theme and input method.
    if state.page == ToolsPage: state.tool = item.index
    elif state.page == WorkbenchPage: state.workbench = item.index
    case item.action
    of SelectGame: state.selected = item.index
    of ShowGames: state.page = GamesPage
    of ShowTools: state.page = ToolsPage
    of ShowAppearance: state.beginAppearance()
    of SelectTheme: state.previewTheme = MenuTheme(item.index)
    of ApplyTheme: state.applyAppearance(preferencesPath)
    of CancelAppearance: state.cancelAppearance()
    of SelectFilter:
      state.filter = item.index
      state.selected = 0
    of PreviousFilter, NextFilter:
      let count = index.filters().len
      state.filter = (state.filter + count + (if item.action == NextFilter: 1 else: -1)) mod count
      state.selected = 0
    else:
      if item.action == PlayGame and jobKind == "startup-probe":
        cancelJob()
        waitingForNetwork = false
      if state.busy: return
      waitingForNetwork = false
      case item.action
      of PlayGame:
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
      of TestHardware:
        closeScreens()
        try:
          discard runTester(getAppDir() / "mono-retro-hwtest", @["test", "--seconds:3600"] & displayArguments, stopping)
        finally:
          if not stopping(): openScreens()
      of ShowSystem: state.page = SystemPage
      of ShowCollections:
        state.page = CollectionsPage
        startJob("collections")
      of ConnectRomm:
        state.page = PairPage
        startJob("pair")
      of SyncRomm: startJob("sync")
      of DisconnectRomm: startJob("disconnect")
      of RebootDevice, ShutdownDevice:
        state.reboot = item.action == RebootDevice
        state.page = PowerPage
        state.confirmYes = false
      of RescanGames:
        syncAfterScan = false
        startJob("scan")
      of ToggleCollection:
        if item.index in 0 ..< index.collections.len:
          state.collection = item.index
          startJob("select", @["--id:" & $index.collections[item.index].id])
      of CancelDialog: state.page = state.theme.homePage()
      of ConfirmPower:
        let reason = power.powerBlockReason()
        if reason.len > 0: raise newException(IOError, reason)
        var request = requestPower(if state.reboot: RebootSystem else: ShutdownSystem)
        try:
          discard request.waitForExit()
          checkPowerRequest(request, if state.reboot: RebootSystem else: ShutdownSystem)
        finally:
          if request != nil: request.close()
        state.message = "Power request accepted"
        state.page = state.theme.homePage()
      of UseLocalSave, UseRemoteSave:
        let games = index.visibleGames(state.filter)
        if games.len > 0:
          pendingGame = games[state.selected].hash
          startJob("resolve", @["--game:" & pendingGame,
            "--choice:" & (if item.action == UseRemoteSave: "server" else: "local")])
          state.page = GamesPage
      else: discard

  try:
    state.theme = if themeOverride.len > 0: parseTheme(themeOverride) else: loadTheme(preferencesPath)
  except CatchableError as error:
    stderr.writeLine("Menu preferences: " & error.msg)
    state.message = error.msg
    state.error = true
  state.page = state.theme.homePage()
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
          if jobKind == "startup-probe":
            if code == 0:
              waitingForNetwork = false
              startJob("sync")
            else:
              waitingForNetwork = getMonoTime() < networkDeadline
              networkProbeAt = getMonoTime() + initDuration(milliseconds = NetworkProbeIntervalMs)
              state.error = false
              state.message = if waitingForNetwork:
                "RomM offline; waiting for network. Local games are available."
              else: "RomM offline; local games are available. Use Sync now to retry."
          else:
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
              waitingForNetwork = true
              networkProbeAt = getMonoTime()
            elif code == 0 and jobKind in ["pair", "select"]:
              if jobKind == "pair":
                if state.page == AppearancePage: state.appearanceReturn = CollectionsPage
                else: state.page = CollectionsPage
              startJob("sync")
        except CatchableError as error:
          state.message = error.msg
          state.error = true
        dirty = true
        state.transition = 0
        transitionStarted = getMonoTime()
    if waitingForNetwork and job == nil and getMonoTime() >= networkProbeAt:
      startJob("probe")
      jobKind = "startup-probe"
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
          if state.page == AppearancePage:
            state.cancelAppearance()
            dirty = true
            continue
          let cancelling = job != nil
          if job != nil:
            cancelJob()
            waitingForNetwork = false
            pendingGame = ""
            state.message = "Cancelled; local files are preserved"
          if state.page in {WorkbenchPage, GamePage}: state.page = GamesPage
          elif state.page != state.theme.homePage(): state.page = state.theme.homePage()
          elif desktop and not cancelling: quit = true
        elif action == OpenTools:
          if state.page != AppearancePage: state.page = ToolsPage
        elif action in {PreviousFilter, NextFilter}:
          if state.page == AppearancePage:
            state.moveSelection(index, screen.width(screen.count() - 1), screen.height(screen.count() - 1),
              if action == NextFilter: 1 else: -1, false)
          elif state.page in {GamesPage, GamePage}:
            activate(ViewTarget(action: if action == NextFilter: ViewAction.NextFilter else: ViewAction.PreviousFilter))
        elif action in {MoveUp, MoveDown, MoveLeft, MoveRight}:
          let direction = if action in {MoveUp, MoveLeft}: -1 else: 1
          state.moveSelection(index, screen.width(screen.count() - 1), screen.height(screen.count() - 1),
            direction, action in {MoveUp, MoveDown})
        elif action == ActivateTarget:
          let item = pendingTargets[0]
          pendingTargets.delete(0)
          if armed:
            armed = false
            activate(item)
        elif not armed: discard
        elif action == Favourite:
          let games = index.visibleGames(state.filter)
          if not state.busy and state.page in {GamesPage, GamePage} and games.len > 0:
            startJob("favourite", @["--game:" & games[state.selected].hash])
        elif action == Details:
          if state.page in {GamesPage, GamePage}: state.page = GamePage
        elif action == OpenGame:
          armed = false
          activate(state.selectedTarget())
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
