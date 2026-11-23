import
  std/[json, monotimes, os, osproc, streams, strutils, tempfiles, times, unicode],
  paddy, pixie, windy,
  ../touchkeyboard,
  ./[anbernic, audioroute, bluetooth, bluetoothworker, browser, display, gamepad, gamelibrary, input, libraryview,
    menu, menuthemes, powercontrol, settings, systeminfo, systemvolume,
    testerprocess, volumeui, wifi]

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
  WifiStatusIntervalMs = 2000
  WifiConnectTimeoutSeconds = 45
  WifiPasswordLimit = 64
  AudioReadyWaitSeconds = 15

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
    wifiHelper = getAppDir() / "mono-retro-wifi"
    wifiProgressPath = jobDirectory / "wifi-progress.json"
    wifiResultPath = jobDirectory / "wifi-result.json"
    bluetoothWorker = newBluetoothWorker(getAppDir() / "mono-retro-bluetooth",
      jobDirectory / "bluetooth-state.json")
    started = getMonoTime()
    preferencesPath = themePreferencesPath()
  createDir(jobDirectory)
  setFilePermissions(jobDirectory, {fpUserRead, fpUserWrite, fpUserExec})
  var
    state: LibraryViewState
    index: LibraryIndex
    storedIndex: LibraryIndex
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
    browserJob: Process
    jobKind: string
    wifiJob: Process
    wifiKind: string
    keepWifiMessage: bool
    wifiStatusAt = started
    pendingGame, offlineGame: string
    syncAfterScan = fileExists(paths.credentials)
    waitingForNetwork = false
    networkProbeAt = started
    networkDeadline = started + initDuration(seconds = StartupNetworkWaitSeconds)
    quit = false
    sizes: seq[IVec2]
    bluetoothReturn = BluetoothPage
    audioGame: string
    audioTester, retryAudio, audioApproved: bool
    audioRetryStarted: MonoTime

  proc activeKeyboard(): var TouchKeyboard =
    ## Use the same keyboard component for Wi-Fi and Bluetooth pairing.
    if state.page == BluetoothKeyboardPage: return state.bluetooth.keyboard
    return state.wifi.keyboard

  proc sendBluetooth(action: string, address = "", value = "", enabled = false) =
    ## Keep radio commands asynchronous and pairing input out of arguments.
    bluetoothWorker.send(BtCommand(action: action, address: address, value: value, enabled: enabled))
    state.bluetooth.state = bluetoothWorker.state
    state.bluetooth.message = ""
    dirty = true

  proc refreshAudioSelection() =
    ## Show the output that will be used by newly launched playback apps.
    let output = loadAudioOutput()
    state.bluetooth.audioAddress = output.address
    state.bluetooth.audioName = output.name

  proc closeScreens() =
    ## Release gamepads, touch, volume and display handles before a child starts.
    bluetoothWorker.close()
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
    state.pairingUrl = ""

  proc stopWifiJob() =
    ## Ask the Wi-Fi worker to stop; a connect restores the previous network first.
    if wifiJob != nil and wifiJob.running(): wifiJob.terminate()

  defer:
    if browserJob != nil: browserJob.close()
    bluetoothWorker.close()
    if wifiJob != nil:
      stopWifiJob()
      if wifiJob.waitForExit(10000) == -1:
        wifiJob.kill()
        discard wifiJob.waitForExit()
      wifiJob.close()
    cancelJob()
    closeScreens()
    if fileExists(progressPath): removeFile(progressPath)
    removeDir(jobDirectory)

  proc startJob(command: string, extra: seq[string] = @[]) =
    ## Delegate network and scan work to the same CLI available to humans.
    if job != nil: raise newException(IOError, "Library operation is already running")
    if wifiKind == "connect" and wifiJob != nil:
      raise newException(IOError, "Wi-Fi is changing; try again when it finishes")
    if fileExists(progressPath): removeFile(progressPath)
    job = startProcess(helper, args = @[command, "--library:" & paths.root,
      "--config:" & paths.config, "--progress:" & progressPath,
      "--name:" & settings.title] & extra, options = {poParentStreams})
    jobKind = command
    state.busy = true
    state.error = false
    state.message = "Working…"
    dirty = true

  proc startWifi(command: string, extra: seq[string] = @[], password = "") =
    ## Run the Wi-Fi worker; a password travels only through its standard input.
    if wifiJob != nil: return
    if not fileExists(wifiHelper):
      state.wifi.unavailable = true
      state.wifi.error = true
      state.wifi.message = "Wi-Fi settings are not installed on this device"
      return
    for path in [wifiProgressPath, wifiResultPath]:
      if fileExists(path): removeFile(path)
    wifiJob = startProcess(wifiHelper, args = @[command, "--progress:" & wifiProgressPath,
      "--result:" & wifiResultPath] & extra, options = {})
    let input = wifiJob.inputStream
    if password.len > 0: input.write(password & "\n")
    input.close()
    wifiKind = command
    state.wifi.busy = true
    state.wifi.connecting = command == "connect"
    state.wifi.error = false
    state.wifi.message = if command == "connect": "Connecting…" else: "Checking Wi-Fi…"
    dirty = true

  proc finishWifi() =
    ## Apply a finished worker's result to the view.
    let code = wifiJob.waitForExit()
    wifiJob.close()
    wifiJob = nil
    let
      kind = wifiKind
      keepMessage = keepWifiMessage
    wifiKind = ""
    keepWifiMessage = false
    state.wifi.busy = false
    state.wifi.connecting = false
    dirty = true
    var output: JsonNode
    try: output = parseFile(wifiResultPath)
    except CatchableError:
      state.wifi.error = true
      state.wifi.message = "Wi-Fi worker failed (code " & $code & ")"
      return
    if output.hasKey("error"):
      if keepMessage and kind != "status": return
      state.wifi.error = true
      state.wifi.message = output["error"].getStr()
      if "restore incomplete" in state.wifi.message:
        state.wifi.message = "Recovery incomplete: " & state.wifi.message
      if kind != "connect":
        state.wifi.unavailable = "unavailable" in state.wifi.message
        state.wifi.status.state = "UNKNOWN"
        state.wifi.status.ipAddress = ""
        return
      if output{"cancelled"}.getBool():
        state.wifi.message = if "restore incomplete" in state.wifi.message: state.wifi.message
          else: "Cancelled; previous Wi-Fi configuration restored"
    else:
      state.wifi.unavailable = false
      if not keepMessage: state.wifi.error = false
      if output.hasKey("status"):
        state.wifi.status = statusFromJson(output["status"])
        for network in state.wifi.networks.mitems:
          network.current = state.wifi.status.state == "COMPLETED" and
            network.savedId >= 0 and network.savedId == state.wifi.status.networkId
      if output.hasKey("networks"):
        let selected = if state.wifi.networks.len > 0:
          state.wifi.networks[clamp(state.wifi.selected, 0, state.wifi.networks.high)].ssidHex else: ""
        state.wifi.networks.setLen(0)
        for node in output["networks"]: state.wifi.networks.add networkFromJson(node)
        state.wifi.selected = 0
        for position, network in state.wifi.networks:
          if network.ssidHex == selected: state.wifi.selected = position
        if not keepMessage:
          state.wifi.message = $state.wifi.networks.len & " networks" &
            (if output{"fresh"}.getBool(): "" else: " (earlier scan results)")
      if kind == "connect":
        let readiness = output{"readiness"}.getStr()
        state.wifi.message = (if readiness.len > 0: readiness & "; " else: "") &
          "Connected to " & output["ssid"].getStr() & " (" & output["ipAddress"].getStr() & ")"
        if fileExists(paths.credentials) and job == nil:
          waitingForNetwork = true
          networkProbeAt = getMonoTime()
          networkDeadline = getMonoTime() + initDuration(seconds = StartupNetworkWaitSeconds)
        let saveError = output{"saveError"}.getStr()
        if saveError.len > 0:
          state.wifi.message = saveError
          state.wifi.error = true
    if kind == "connect":
      let message = state.wifi.message
      let failed = state.wifi.error
      startWifi("scan", @["--cached"])
      keepWifiMessage = true
      state.wifi.message = message
      state.wifi.error = failed

  proc beginWifiConnect(network: WifiNetwork, password: string) =
    ## Start a human-requested connection without interrupting library storage work.
    if job != nil and jobKind == "startup-probe":
      cancelJob()
      waitingForNetwork = false
    if job != nil:
      raise newException(IOError, "Wait for the current library operation before changing Wi-Fi")
    if wifiKind == "connect": raise newException(IOError, "Wi-Fi is already connecting")
    if wifiJob != nil:
      raise newException(IOError, "Wi-Fi is still checking networks; wait for it to finish or use Back")
    var arguments = @["--timeout:" & $WifiConnectTimeoutSeconds]
    if network.savedId >= 0: arguments.add "--network:" & $network.savedId
    else:
      arguments.add ["--ssid-hex:" & network.ssidHex,
        "--security:" & (if network.security == OpenSecurity: "open" else: "personal")]
      if network.security == PersonalSecurity:
        validatePassword(password)
        arguments.add "--password-stdin"
    startWifi("connect", arguments, password)
    waitingForNetwork = false

  proc keyboardLayout(): KeyboardLayout =
    ## Lay out the password keyboard on the touch screen.
    let last = screen.count() - 1
    activeKeyboard().keyboardLayout(keyboardArea(screen.width(last), screen.height(last)))

  proc keyboardResult(outcome: KeyboardResult) =
    ## Leave or submit the password page after a keyboard action.
    if state.page == BluetoothKeyboardPage:
      case outcome
      of KeyboardSubmitted:
        let text = state.bluetooth.keyboard.text
        if text.len == 0 or (state.bluetooth.state.prompt.kind == PasskeyPrompt and
            not text.allCharsInSet(Digits)):
          state.bluetooth.keyboard.label = if state.bluetooth.state.prompt.kind == PasskeyPrompt:
            "Use 1–6 digits" else: "Enter the device PIN"
          dirty = true
          return
        sendBluetooth("reply", value = state.bluetooth.keyboard.text)
      of KeyboardCancelled:
        sendBluetooth("cancel")
        state.bluetooth.keyboard.clear()
        state.page = bluetoothReturn
      else: discard
      dirty = true
      return
    case outcome
    of KeyboardSubmitted:
      let network = state.wifi.networks[clamp(state.wifi.selected, 0, state.wifi.networks.high)]
      try:
        beginWifiConnect(network, state.wifi.keyboard.text)
        state.wifi.keyboard.clear()
        state.page = WifiPage
      except CatchableError as error:
        state.wifi.message = error.msg
        state.wifi.error = true
    of KeyboardCancelled:
      state.wifi.keyboard.clear()
      state.page = WifiPage
    else: discard
    dirty = true

  proc reload() =
    ## Read a complete snapshot only after a writer has published it.
    paths.requireStorage(config)
    storedIndex = paths.loadIndex()
    index = storedIndex.withApplications(config)
    ui.clearCovers()
    state.filter = clamp(state.filter, 0, index.filters().high)
    state.selected = clamp(state.selected, 0, max(0, index.visibleGames(state.filter).high))

  proc pointer(phase: TouchPhase, point: Vec2, screenIndex: int, id = 0'i32) =
    ## Select covers on tap and require a separate Play action to launch.
    if screen.count() > 1 and screenIndex == 0: return
    if state.page in {WifiPasswordPage, BluetoothKeyboardPage} and screenIndex == screen.count() - 1:
      if phase == TouchBegin and pointerId == -1:
        pointerId = id
        pointerScreen = screenIndex
      elif phase in {TouchEnd, TouchCancel} and pointerId == id:
        pointerId = -1
        pointerScreen = -1
        if phase == TouchEnd: keyboardResult(activeKeyboard().tap(keyboardLayout(), point))
        dirty = true
      return
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
      screen.window(screenIndex).onRune = proc(rune: Rune) =
        # The keyboard rejects invalid UTF-8 by raising, so drop invalid code points here.
        let text = $rune
        if state.page in {WifiPasswordPage, BluetoothKeyboardPage} and text.validateUtf8() == -1 and
            activeKeyboard().insert(text) != KeyboardIgnored:
          dirty = true
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
    refreshAudioSelection()
    if state.bluetooth.audioAddress.len > 0: sendBluetooth("status")

  proc allowAudio(gameHash: string, tester: bool): bool =
    ## Require an available selected output before releasing the launcher's screens.
    refreshAudioSelection()
    if state.bluetooth.audioAddress.len == 0: return true
    if audioApproved:
      audioApproved = false
      return true
    if bluetoothWorker.fresh and bluetoothWorker.state.available and
        bluetoothWorker.state.error.len == 0:
      for device in bluetoothWorker.state.devices:
        if device.address == state.bluetooth.audioAddress and device.audioReady: return true
    audioGame = gameHash
    audioTester = tester
    state.bluetooth.action = 0
    state.page = AudioUnavailablePage
    sendBluetooth("status")
    state.bluetooth.message = "Connect headphones, retry, or choose speakers."
    return false

  proc play(hash: string) =
    ## Validate mounted content and use the player's orderly save/exit lifecycle.
    if not allowAudio(hash, false): return
    var lock = paths.lockLibrary(config)
    defer: lock.close()
    var game: LibraryGame
    for candidate in storedIndex.games:
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
    paths.saveIndex(storedIndex)
    lock.close()
    if fileExists(paths.credentials): startJob("sync")

  proc launchTester() =
    ## Share output readiness and orderly child handoff with game launches.
    if not allowAudio("", true): return
    closeScreens()
    try:
      let code = runTester(getAppDir() / "mono-retro-hwtest",
        @["test", "--seconds:3600"] & displayArguments, stopping)
      if code != 0: raise newException(IOError, "Hardware Test exited with code " & $code)
    finally:
      if not stopping(): openScreens()

  proc launchPendingAudio() =
    ## Resume only the app the user already requested from the unavailable dialog.
    let
      hash = move(audioGame)
      tester = audioTester
    audioTester = false
    retryAudio = false
    state.page = state.theme.homePage()
    if tester: launchTester()
    elif hash.len > 0: play(hash)

  proc activate(item: ViewTarget) =
    ## Keep application operations shared across every theme and input method.
    if state.page == ToolsPage: state.tool = item.index
    elif state.page == WorkbenchPage: state.workbench = item.index
    case item.action
    of OpenRommLink:
      if desktop and state.page == PairPage:
        if browserJob != nil:
          if browserJob.running(): return
          discard browserJob.waitForExit()
          browserJob.close()
          browserJob = nil
        browserJob = openPairingLink(state.pairingUrl, config.rommUrl)
        state.error = false
    of SelectGame: state.selected = item.index
    of ShowGames: state.page = GamesPage
    of ShowTools: state.page = ToolsPage
    of ShowAppearance: state.beginAppearance()
    of ShowSettings:
      if state.page == BluetoothPage: sendBluetooth("cancel")
      state.page = SettingsPage
    of ShowBluetooth:
      refreshAudioSelection()
      state.page = BluetoothPage
      sendBluetooth("status")
    of ScanBluetooth: sendBluetooth("scan", enabled = true)
    of PowerBluetooth:
      sendBluetooth("power", enabled = not state.bluetooth.state.powered)
    of SelectBluetoothDevice:
      if item.index in 0 ..< state.bluetooth.state.devices.len:
        state.bluetooth.device = state.bluetooth.state.devices[item.index]
        state.bluetooth.selected = item.index + 1
        state.bluetooth.action = 0
        state.page = BluetoothDevicePage
    of ReturnBluetooth:
      if state.bluetooth.state.busy: sendBluetooth("cancel")
      state.page = BluetoothPage
      state.bluetooth.confirm = false
    of ConnectBluetooth:
      let device = state.bluetooth.bluetoothDevice()
      sendBluetooth(if device.paired: "connect" else: "pair", device.address)
    of DisconnectBluetooth:
      sendBluetooth("disconnect", state.bluetooth.device.address)
    of ForgetBluetooth:
      state.page = BluetoothForgetPage
      state.bluetooth.confirm = false
    of ConfirmForgetBluetooth:
      sendBluetooth("forget", state.bluetooth.device.address)
      state.page = BluetoothPage
    of UseSpeakerAudio, UseBluetoothAudio:
      if item.action == UseSpeakerAudio:
        saveAudioOutput(AudioOutputSelection())
      else:
        let device = state.bluetooth.bluetoothDevice()
        if not device.audioReady: raise newException(IOError, "Headphone audio is not ready")
        saveAudioOutput(AudioOutputSelection(address: device.address, name: device.name))
      refreshAudioSelection()
      state.bluetooth.message = "Output selected for the next app launch."
    of AcceptBluetoothPrompt, RejectBluetoothPrompt:
      sendBluetooth("reply", value = if item.action == AcceptBluetoothPrompt: "yes" else: "no")
      state.page = bluetoothReturn
    of RetryAudio:
      retryAudio = true
      audioRetryStarted = getMonoTime()
      sendBluetooth("connect", state.bluetooth.audioAddress)
      state.bluetooth.message = "Connecting headphones…"
    of SpeakerAudio:
      saveAudioOutput(AudioOutputSelection())
      refreshAudioSelection()
      launchPendingAudio()
    of CancelAudio:
      if retryAudio: sendBluetooth("cancel")
      retryAudio = false
      audioGame = ""
      audioTester = false
      state.page = state.theme.homePage()
    of ShowWifi:
      state.page = WifiPage
      startWifi("scan")
    of RescanWifi: startWifi("scan")
    of SelectWifiNetwork:
      if item.index in 0 ..< state.wifi.networks.len and not state.wifi.connecting:
        state.wifi.selected = item.index
        let network = state.wifi.networks[item.index]
        state.wifi.error = false
        if network.security notin SupportedSecurity:
          state.wifi.message = SecurityNames[network.security]
          state.wifi.error = true
        elif network.current:
          state.wifi.message = "Already connected to " & network.ssid
        elif network.savedId >= 0 or network.security == OpenSecurity:
          state.page = WifiConfirmPage
        else:
          state.wifi.keyboard = newTouchKeyboard(label = "Password", submitLabel = "Connect",
            maxRunes = WifiPasswordLimit, asciiOnly = true)
          state.page = WifiPasswordPage
    of ConnectWifi:
      if state.wifi.networks.len > 0:
        state.page = WifiPage
        beginWifiConnect(state.wifi.networks[clamp(state.wifi.selected, 0, state.wifi.networks.high)], "")
    of CancelWifi: state.page = WifiPage
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
      if item.action in {PlayGame, TestHardware, OpenGrimoire} and
          (state.bluetooth.state.busy or state.bluetooth.state.prompt.kind != NoPrompt):
        raise newException(IOError, "Finish or cancel the Bluetooth operation first")
      if item.action in {PlayGame, TestHardware, OpenGrimoire} and wifiKind == "connect":
        raise newException(IOError, "Wait for Wi-Fi to finish connecting")
      if item.action in {PlayGame, OpenGrimoire} and jobKind == "startup-probe":
        cancelJob()
        waitingForNetwork = false
      if item.action == OpenGrimoire and state.busy:
        raise newException(IOError, "Wait for the current library operation before opening Grimoire")
      if state.busy: return
      waitingForNetwork = false
      case item.action
      of PlayGame:
        let games = index.visibleGames(state.filter)
        if games.len > 0:
          let hash = games[state.selected].hash
          if hash == GrimoireApplicationHash:
            activate(ViewTarget(action: OpenGrimoire))
          elif games[state.selected].saveConflict:
            state.page = ConflictPage
            state.confirmYes = false
          elif fileExists(paths.credentials) and offlineGame != hash:
            pendingGame = hash
            startJob("sync-saves", @["--game:" & hash])
          else:
            offlineGame = ""
            play(hash)
      of TestHardware:
        launchTester()
      of OpenGrimoire:
        if config.grimoireCommand.len == 0:
          raise newException(IOError, "Grimoire is not configured; set grimoireCommand in the library configuration")
        if not fileExists(config.grimoireCommand[0]):
          raise newException(IOError, "Grimoire is not installed at " & config.grimoireCommand[0])
        closeScreens()
        var code: int
        try:
          code = runTester(config.grimoireCommand[0], config.grimoireCommand[1 .. ^1], stopping)
        finally:
          if not stopping(): openScreens()
        if code != 0: raise newException(IOError, "Grimoire exited with code " & $code)
        state.message = ""
        state.error = false
      of ShowSystem: state.page = SystemPage
      of ShowCollections:
        state.page = CollectionsPage
        startJob("collections")
      of ConnectRomm:
        state.pairingUrl = ""
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
    refreshAudioSelection()
    if state.bluetooth.audioAddress.len > 0: sendBluetooth("status")
    startJob("scan")
  except CatchableError as error:
    state.message = error.msg
    state.error = true

  while not quit and not stopping() and
      (duration == 0 or (getMonoTime() - started).inSeconds < duration):
    if not screen.poll(escapeCloses = false): break
    if browserJob != nil and not browserJob.running():
      let code = browserJob.waitForExit()
      browserJob.close()
      browserJob = nil
      if code != 0:
        state.error = true
        state.message = "Could not open the browser; use the displayed link."
        dirty = true
    if job != nil:
      if fileExists(progressPath):
        let progress = parseFile(progressPath)
        let message = progress.stringField("message")
        if desktop and jobKind == "pair" and isPairingLink(message, config.rommUrl):
          state.pairingUrl = message
        if message != state.message and not (jobKind == "pair" and state.error):
          state.message = message
          dirty = true
      if not job.running():
        let code = job.waitForExit()
        job.close()
        job = nil
        state.pairingUrl = ""
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
    if wifiJob != nil:
      if fileExists(wifiProgressPath):
        try:
          let message = parseFile(wifiProgressPath).stringField("message")
          if message.len > 0 and message != state.wifi.message:
            state.wifi.message = message
            dirty = true
        except CatchableError: discard
      if not wifiJob.running(): finishWifi()
    try:
      if bluetoothWorker.poll():
        let
          previousPrompt = state.bluetooth.state.prompt
          selectedAddress = if state.bluetooth.selected > 0 and
              state.bluetooth.selected <= state.bluetooth.state.devices.len:
            state.bluetooth.state.devices[state.bluetooth.selected - 1].address else: ""
        state.bluetooth.state = bluetoothWorker.state
        if selectedAddress.len > 0:
          state.bluetooth.selected = 0
          for position, device in state.bluetooth.state.devices:
            if device.address == selectedAddress: state.bluetooth.selected = position + 1
        let prompt = state.bluetooth.state.prompt
        if prompt.kind != NoPrompt and prompt != previousPrompt and state.page in {
            BluetoothPage, BluetoothDevicePage, BluetoothPromptPage, BluetoothKeyboardPage}:
          if state.page notin {BluetoothPromptPage, BluetoothKeyboardPage}: bluetoothReturn = state.page
          state.bluetooth.confirm = false
          if prompt.kind in {PinPrompt, PasskeyPrompt}:
            state.bluetooth.keyboard = newTouchKeyboard(label = "Bluetooth PIN",
              submitLabel = "Pair", maxRunes = if prompt.kind == PasskeyPrompt: 6 else: 16,
              masked = false, asciiOnly = true)
            state.page = BluetoothKeyboardPage
          else: state.page = BluetoothPromptPage
        elif prompt.kind == NoPrompt and previousPrompt.kind != NoPrompt and
            state.page in {BluetoothPromptPage, BluetoothKeyboardPage}:
          state.bluetooth.keyboard.clear()
          state.page = bluetoothReturn
        dirty = true
      if retryAudio:
        var ready = false
        for device in state.bluetooth.state.devices:
          if device.address == state.bluetooth.audioAddress and device.audioReady: ready = true
        if bluetoothWorker.fresh and ready and not state.bluetooth.state.busy:
          audioApproved = true
          launchPendingAudio()
        elif (bluetoothWorker.fresh and state.bluetooth.state.error.len > 0) or
            (getMonoTime() - audioRetryStarted).inSeconds >= AudioReadyWaitSeconds:
          let failure = state.bluetooth.state.error
          sendBluetooth("cancel")
          retryAudio = false
          state.bluetooth.message = if failure.len > 0: failure
            else: "Headphone audio is not ready. Retry or choose speakers."
          dirty = true
    except CatchableError as error:
      retryAudio = false
      state.bluetooth.state.error = error.msg
      if state.page notin {BluetoothPage, BluetoothDevicePage, BluetoothPromptPage,
          BluetoothKeyboardPage, BluetoothForgetPage, AudioUnavailablePage}:
        state.message = error.msg
        state.error = true
      dirty = true
    if state.page == WifiPage and wifiJob == nil and not state.wifi.unavailable and
        getMonoTime() >= wifiStatusAt:
      let
        message = state.wifi.message
        failed = state.wifi.error
      startWifi("status")
      keepWifiMessage = true
      state.wifi.message = message
      state.wifi.error = failed
      wifiStatusAt = getMonoTime() + initDuration(milliseconds = WifiStatusIntervalMs)
    if waitingForNetwork and job == nil and wifiKind != "connect" and getMonoTime() >= networkProbeAt:
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
        if state.page in {WifiPasswordPage, BluetoothKeyboardPage}:
          # Letter keys type through onRune, so only editing keys map to actions here.
          if window.buttonPressed[KeyBackspace]: discard activeKeyboard().backspace(); dirty = true
          for (key, action) in [(KeyUp, MoveUp), (KeyDown, MoveDown), (KeyLeft, PreviousFilter),
              (KeyRight, NextFilter), (KeyEnter, OpenTools), (KeyEscape, GoBack)]:
            if window.buttonPressed[key]: pending.add action
        else:
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
        if state.page in {WifiPasswordPage, BluetoothKeyboardPage} and action != ActivateTarget:
          let layout = keyboardLayout()
          case action
          of MoveUp, MoveDown, MoveLeft, MoveRight:
            discard activeKeyboard().moveFocus(layout,
              (if action == MoveLeft: -1 elif action == MoveRight: 1 else: 0),
              (if action == MoveUp: -1 elif action == MoveDown: 1 else: 0))
          of OpenGame:
            if armed:
              armed = false
              keyboardResult(activeKeyboard().activateFocused(layout))
          of GoBack: keyboardResult(KeyboardCancelled)
          of Details: discard activeKeyboard().backspace()
          of Favourite: discard activeKeyboard().pressAction(ShiftKey)
          of OpenTools: keyboardResult(KeyboardSubmitted)
          of PreviousFilter: discard activeKeyboard().moveCursor(-1)
          of NextFilter: discard activeKeyboard().moveCursor(1)
          else: discard
          dirty = true
          continue
        if state.page in {BluetoothPage, BluetoothDevicePage, BluetoothPromptPage,
            BluetoothForgetPage, AudioUnavailablePage}:
          if action == GoBack:
            case state.page
            of BluetoothPage:
              sendBluetooth("cancel")
              state.page = SettingsPage
            of BluetoothPromptPage:
              sendBluetooth("cancel")
              state.page = bluetoothReturn
            of AudioUnavailablePage: activate(ViewTarget(action: CancelAudio))
            else:
              if state.bluetooth.state.busy: sendBluetooth("cancel")
              state.page = BluetoothPage
            dirty = true
            continue
          if action == Details and state.page == BluetoothPage:
            activate(ViewTarget(action: ScanBluetooth))
            continue
          if action == Favourite and state.page == BluetoothPage:
            activate(ViewTarget(action: PowerBluetooth))
            continue
        if action == GoBack and state.page in {SettingsPage, WifiPage, WifiConfirmPage}:
          if state.page == WifiConfirmPage: state.page = WifiPage
          elif state.page == WifiPage and wifiKind == "connect":
            stopWifiJob()
            state.wifi.message = "Cancelling; restoring the previous connection…"
          elif state.page == WifiPage:
            stopWifiJob()
            state.page = SettingsPage
          else: state.page = state.theme.homePage()
          dirty = true
          continue
        if action == Details and state.page == WifiPage:
          startWifi("scan")
          dirty = true
          continue
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
          if state.page == AudioUnavailablePage: activate(ViewTarget(action: CancelAudio))
          elif state.page in {BluetoothPromptPage, BluetoothKeyboardPage}: discard
          elif state.page in {BluetoothPage, BluetoothDevicePage, BluetoothForgetPage}:
            sendBluetooth("cancel")
            state.page = ToolsPage
          elif state.page != AppearancePage: state.page = ToolsPage
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
          if not state.busy and state.page in {GamesPage, GamePage} and games.len > 0 and
              games[state.selected].hash != GrimoireApplicationHash:
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
