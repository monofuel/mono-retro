import
  std/[monotimes, os, osproc, parseopt, posix, strutils, times],
  paddy, pixie, windy,
  retro/[anbernic, display, gamepad, input, launcherui, menu, powercontrol, settings,
    systeminfo, systemvolume, testerprocess, volumeui]

const
  InputIntervalMs = 8
  BatteryIntervalMs = 2000
  NetworkIntervalMs = 5000
  StickThreshold = 0.6'f32
  StickRelease = 0.3'f32
  WheelNotch = 10'f32
  Help = """Usage: mono-retro [--tester:PATH] [--decompbound:PATH] [--lost-in-blue:PATH] [--seconds:N] [device/display options]
Hardware Test, System Info, Reboot, Shut Down, Decompbound and installed Lost in Blue.
Use arrows/D-pad/stick, A/Enter to open, and B/Back/Escape to return.
The tester's Select+Start exit returns to the launcher.
Device/display/profile options match mono-retro-hwtest.
"""

var stopping = false

proc stopHandler(signal: cint) {.noconv.} =
  ## Ask the event loop or tester supervisor to release hardware normally.
  stopping = true

proc main() =
  ## Run the menu independently of the diagnostic application's process.
  var
    arguments: seq[string]
    tester = getAppDir() / "mono-retro-hwtest"
    decompbound = getAppDir() / "mono-retro-decompbound"
    lostInBlue = getAppDir() / "mono-retro-lost-in-blue"
    duration = 0
    parser = initOptParser(commandLineParams())
  for kind, key, value in parser.getopt():
    if kind == cmdLongOption and key == "tester": tester = absolutePath(value)
    elif kind == cmdLongOption and key == "decompbound": decompbound = absolutePath(value)
    elif kind == cmdLongOption and key == "lost-in-blue": lostInBlue = absolutePath(value)
    elif kind == cmdLongOption and key == "seconds":
      duration = parseInt(value)
      if duration < 1: raise newException(ValueError, "Duration must be positive")
    elif kind == cmdLongOption and key == "help":
      stdout.write(Help)
      return
    elif kind == cmdLongOption: arguments.add "--" & key & (if value.len > 0: ":" & value else: "")
    else: raise newException(ValueError, "Expected a launcher option")
  let
    settings = parseSettings(arguments, detectDevice())
    desktop = settings.displayBackend() == "x11"
    ui = newLauncherUi()
    identity = localSystem()
    started = getMonoTime()
  posix.signal(SIGINT, stopHandler)
  posix.signal(SIGTERM, stopHandler)
  var
    screen: Display
    backInputs: seq[InputDevice]
    state = MenuState(lostInBlue: fileExists(lostInBlue))
    power = readPower(settings.batterySupply, currentSupply = settings.batteryCurrentSupply)
    network = localNetwork()
    lastBattery = getMonoTime()
    lastNetwork = getMonoTime()
    dirty = true
    stickReady = true
    maxScroll = 0
    pending: seq[MenuInput]
    pointerId = -1'i32
    pointerScreen = -1
    pointerStart, pointerLast: Vec2
    pointerButton = false
    pointerCancel = false
    mouseHeld = false
    sizes: seq[IVec2]
    pendingPower = NoAction
    requestedPower = NoAction
    powerRequest: Process
    volume: SystemVolume
    volumeUi = newVolumeUi()
    volumeImage: Image
    volumeVisible = false
  defer:
    volume.close()
    if powerRequest != nil: powerRequest.close()
    closeGamepads()
    for device in backInputs: device.close()
    if screen != nil: screen.close()

  proc pointerEvent(phase: TouchPhase, id: int32, point: Vec2, index: int) =
    ## Treat the first finger as a button tap or a direct information scroll.
    if state.busy: return
    let
      role = if screen.count() > 1:
          (if index == 0: TopScreen else: BottomScreen)
        else: SingleScreen
      areas = layout(screen.width(index), screen.height(index), role, state.labels().len)
    case phase
    of TouchBegin:
      if pointerId != -1: return
      pointerId = id
      pointerScreen = index
      pointerStart = point
      pointerLast = point
      pointerCancel = state.confirmation != NoAction and areas.cancel.contains(point)
      pointerButton = role != TopScreen and (if state.confirmation == NoAction:
        areas.action.contains(point) else: pointerCancel or areas.confirm.contains(point))
      if pointerButton and state.confirmation != NoAction:
        state.confirmYes = not pointerCancel
        dirty = true
      if not state.info and state.confirmation == NoAction and role != BottomScreen:
        for row, area in areas.rows:
          if area.contains(point):
            state.selected = row
            dirty = true
    of TouchMove:
      if id != pointerId or index != pointerScreen: return
      if state.info and not pointerButton and areas.body.contains(pointerStart):
        state.scroll = clamp(state.scroll + int(pointerLast.y - point.y), 0, maxScroll)
        dirty = true
      pointerLast = point
    of TouchEnd, TouchCancel:
      if id != pointerId or index != pointerScreen: return
      let releaseArea = if state.confirmation == NoAction: areas.action
        elif pointerCancel: areas.cancel else: areas.confirm
      if phase == TouchEnd and pointerButton and releaseArea.contains(point) and
          abs(point.y - pointerStart.y) < 24:
        pending.add (if state.info or pointerCancel: Back else: Open)
      pointerId = -1

  proc openScreens() =
    ## Recreate display/input ownership after the child has completely exited.
    screen = openDisplay(settings)
    volume = openSystemVolume(settings)
    volumeVisible = false
    sizes.setLen(0)
    for index in 0 ..< screen.count():
      sizes.add screen.window(index).framebufferSize
      let target = index
      screen.window(index).onTouch = proc(event: TouchEvent) =
        pointerEvent(event.phase, event.contact.id, event.contact.position, target)
    if not desktop:
      for binding in settings.bindings:
        if binding.label == "BACK":
          for path in inputPaths(@[binding.device]): backInputs.add openInput(path)
    initGamepads()
    state.armed = false
    pointerId = -1
    mouseHeld = false
    stickReady = false
    pending.setLen(0)
    dirty = true

  openScreens()
  while not stopping and (duration == 0 or (getMonoTime() - started).inSeconds < duration):
    if not screen.poll(escapeCloses = false): break
    if volume != nil:
      let
        nowNs = getMonoTime().ticks
        changed = volume.poll(nowNs)
        visible = volume.visible(nowNs)
      if changed or volumeImage == nil:
        volumeImage = volumeUi.renderVolume(volume.percent, volume.error, 320, volumeImage)
      if changed or visible != volumeVisible: dirty = true
      volumeVisible = visible
    var activationHeld = false
    for rawPad in pollGamepads():
      let
        pad = rawPad.mapAnbernic()
        activate = physicalButton(pad.name, "A")
        cancel = physicalButton(pad.name, "B")
        stick = pad.axis(GamepadLStickY)
      activationHeld = activationHeld or pad.button(activate) or
        pad.button(GamepadSelect) or pad.button(GamepadStart)
      if pad.buttonPressed(GamepadUp): pending.add Previous
      if pad.buttonPressed(GamepadDown): pending.add Next
      if state.confirmation != NoAction:
        if pad.buttonPressed(GamepadLeft): pending.add Previous
        if pad.buttonPressed(GamepadRight): pending.add Next
      if pad.buttonPressed(activate): pending.add Open
      if pad.buttonPressed(cancel): pending.add Back
      if abs(stick) < StickRelease: stickReady = true
      elif stickReady and abs(stick) >= StickThreshold:
        pending.add (if stick > 0: Previous else: Next)
        stickReady = false
    for device in backInputs:
      for event in device.readEvents():
        if event.kind == EventKey and event.code == 158 and event.value == 1: pending.add Back
    if desktop:
      for index in 0 ..< screen.count():
        let window = screen.window(index)
        activationHeld = activationHeld or window.buttonDown[KeyEnter] or window.buttonDown[MouseLeft]
        if window.buttonPressed[KeyUp]: pending.add Previous
        if window.buttonPressed[KeyDown]: pending.add Next
        if state.confirmation != NoAction:
          if window.buttonPressed[KeyLeft]: pending.add Previous
          if window.buttonPressed[KeyRight]: pending.add Next
        if window.buttonPressed[KeyEnter]: pending.add Open
        if window.buttonPressed[KeyEscape]: pending.add Back
        if window.scrollDelta.y != 0 and state.info:
          state.scroll = clamp(state.scroll + int(window.scrollDelta.y * ScrollStep.float32 / WheelNotch), 0, maxScroll)
          dirty = true
        if window.buttonPressed[MouseLeft]:
          pointerEvent(TouchBegin, 0, window.mousePos.vec2, index)
          mouseHeld = true
        if mouseHeld: pointerEvent(TouchMove, 0, window.mousePos.vec2, index)
        if window.buttonReleased[MouseLeft]:
          pointerEvent(TouchEnd, 0, window.mousePos.vec2, index)
          mouseHeld = false
    if not activationHeld: state.armed = true
    var action = NoAction
    for input in pending:
      let next = state.handle(input, desktop)
      if next != NoAction: action = next
      dirty = true
    pending.setLen(0)
    if action == QuitLauncher: break
    if action in {RebootSystem, ShutdownSystem}:
      power = readPower(settings.batterySupply, currentSupply = settings.batteryCurrentSupply)
      state.error = power.powerBlockReason()
      if state.error.len == 0:
        state.busy = true
        pendingPower = action
      dirty = true
    if action in {LaunchTester, LaunchDecompbound, LaunchLostInBlue}:
      let
        child = case action
          of LaunchTester: tester
          of LaunchLostInBlue: lostInBlue
          else: decompbound
        childArguments = if action == LaunchTester: @["test", "--seconds:3600"] & arguments else: @[]
      if not fileExists(child):
        state.error = "Application not found: " & child
      else:
        screen.close()
        screen = nil
        volume.close()
        volume = nil
        closeGamepads()
        for device in backInputs: device.close()
        backInputs.setLen(0)
        try:
          let code = runTester(child, childArguments,
            proc(): bool = stopping)
          state.error = if code == 0: "" else: "Application exited with code " & $code
        except OSError, IOError:
          state.error = getCurrentExceptionMsg()
          stderr.writeLine(state.error)
        if stopping: break
        openScreens()
      dirty = true
    let now = getMonoTime()
    if (now - lastBattery).inMilliseconds >= BatteryIntervalMs:
      let updated = readPower(settings.batterySupply, currentSupply = settings.batteryCurrentSupply)
      if power != updated:
        power = updated
        dirty = true
      lastBattery = now
    if (now - lastNetwork).inMilliseconds >= NetworkIntervalMs:
      let updated = localNetwork()
      if network != updated:
        network = updated
        dirty = true
      lastNetwork = now
    for index in 0 ..< screen.count():
      if sizes[index] != screen.window(index).framebufferSize:
        sizes[index] = screen.window(index).framebufferSize
        dirty = true
    if dirty:
      state.scroll = clamp(state.scroll, 0, maxScroll)
      var lines = @["Device: " & settings.title] & identity
      for index in 0 ..< screen.count(): lines.add "Screen " & $(index + 1) & ": " & screen.describe(index)
      lines.add power.powerLines()
      lines.add network
      for index in 0 ..< screen.count():
        let
          role = if screen.count() == 1: SingleScreen elif index == 0: TopScreen else: BottomScreen
          rendered = ui.render(state, settings.title, power, lines, screen.width(index), screen.height(index), role)
        if volumeVisible and role != TopScreen and volumeImage != nil:
          rendered.image.draw(volumeImage, translate(vec2(
            ((rendered.image.width - volumeImage.width) div 2).float32, 12)))
        if role != TopScreen: maxScroll = rendered.maxScroll
        screen.present(rendered.image, index)
      let bounded = min(state.scroll, maxScroll)
      dirty = state.scroll != bounded
      state.scroll = bounded
    try:
      if pendingPower != NoAction:
        requestedPower = pendingPower
        pendingPower = NoAction
        powerRequest = requestPower(requestedPower)
      checkPowerRequest(powerRequest, requestedPower)
    except OSError, IOError:
      state.busy = false
      state.confirmation = NoAction
      state.error = getCurrentExceptionMsg()
      stderr.writeLine(state.error)
      dirty = true
    sleep(InputIntervalMs)

when isMainModule:
  main()
