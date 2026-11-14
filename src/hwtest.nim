import
  std/[json, monotimes, os, posix, strformat, times],
  paddy, windy,
  retro/[audio, display, gamepad, hardwareaudio, input, pattern, settings, touch]

const
  Help = """Usage: hwtest [test|info|input|audio|calibrate] [options]
  --profile:PATH    Device JSON profile
  --device:NAME     auto (default), rg-sp, rg-ds-plus, generic
  --gamepad:NAME    paddy (default) or raw evdev comparison
  --display:NAME    auto (default), x11, fbdev, drm
  --drm:PATH        DRM device (default /dev/dri/card0)
  --output:NAME     DRM connector; repeat in top/bottom order
  --touch-rotate:N  Touch rotation: 0, 90, 180, 270
  --fb:PATH         Framebuffer (default /dev/fb0)
  --input:PATH      Input device; repeat for multiple devices
  --pcm:NAME        ALSA PCM for the audio command (default default)
  --mute            Disable test-tone playback
  --microphone:on|off  Live mic meter (default on)
  --rotate:DEGREES  0, 90, 180, 270
  --seconds:N       Test duration, 1-3600 (default 300)
  --tone-key:N      Fresh key press that plays sound (default 315 / Start)
  --save-profile:PATH  Calibration output profile
  --preview:PATH    Render a PPM preview without accessing hardware

Test mode never plays sound automatically. Start or desktop Enter plays a short left/right tone.
Speaker output and microphone input bars show live peak levels through Slappy.
Hold Select+Start for two seconds to exit, or use Ctrl+C. Input is observed without an exclusive grab.
Display cleanup runs on normal exit, SIGINT and SIGTERM.
"""

var stopping = false

proc stopHandler(signal: cint) {.noconv.} =
  stopping = true

proc drawMeter(canvas: Canvas, label, status: string, peak: float,
    x, y, width, scale: int) =
  ## Draw one peak meter on a -60 to 0 dBFS scale with its current device status.
  let
    textHeight = 9 * scale
    level = if peak > 0: &"{peak.decibels():.1f} DBFS" else: "SILENT"
    caption = if status.len > 0: status else: level
    barHeight = max(4, textHeight - 5)
  canvas.text(x, y, label, White, scale)
  canvas.text(x + max(0, width - caption.len * 6 * scale), y, caption, Cyan, scale)
  canvas.rect(x, y + textHeight, width, barHeight, Gray)
  canvas.rect(x, y + textHeight, int(width.float * peak.meterFraction()), barHeight,
    if peak >= 0.99: 0xff6040'u32 else: Green)

proc draw(settings: Settings, devices: seq[InputDevice], width, height, tick, tones: int,
    monitor = GamepadMonitor(), levels: HardwareAudio = nil): Canvas =
  result = testPattern(width, height, tick)
  let
    margin = max(8, width div 60)
    scale = max(1, min(width div 300, height div 200))
    textHeight = 9 * scale
    top = max(20, height div 5) + margin
    footer = height - 28 - textHeight * 3
    sideMeters = settings.sticks.len == 1 and width >= 600
    meterReserve = if sideMeters: 0 else: textHeight * 4 + margin
    title = "MONO RETRO - " & settings.title & " - " & settings.gamepad
  result.text(margin, top, title, White, scale)
  result.text(margin, top + textHeight, "PRESS ALL BUTTONS - GREEN MEANS SEEN", Cyan, scale)
  var
    index = 0
    seen = 0
  let
    columns = max(2, width div (10 * 6 * scale))
    cellWidth = (width - margin * 2) div columns
    cellHeight = textHeight + 6
    rows = max(1, (footer - meterReserve - top - textHeight * 2 - margin) div cellHeight)
  var
    meterTop = footer - textHeight * 4 - margin
    meterLeft = margin
  var badges: seq[tuple[label: string, active, seen: bool]]
  if settings.bindings.len > 0:
    for binding in settings.bindings:
      if settings.gamepad == "paddy" and binding.usesPaddy():
        badges.add (binding.label, monitor.active(binding), monitor.observed(binding))
      else:
        let label = binding.label & (if settings.gamepad == "paddy": " RAW" else: "")
        badges.add (label, binding.active(devices), binding.observed(devices))
  else:
    for deviceIndex, device in devices:
      for control in device.controls:
        let active = if control.kind == EventKey: control.value != 0 else: control.axisDirection() != 0
        badges.add ($(deviceIndex + 1) & ":" & control.label(), active, control.seen)
  for badge in badges:
    if badge.seen:
      inc seen
    if index < columns * rows:
      let
        x = margin + (index mod columns) * cellWidth
        y = top + textHeight * 2 + (index div columns) * cellHeight
        color = if badge.active: Cyan elif badge.seen: Green else: Gray
      result.rect(x, y, cellWidth - 3, cellHeight - 3, color)
      result.text(x + 3, y + 3, badge.label, if badge.active or badge.seen: Black else: White, scale)
    inc index
  if settings.sticks.len > 0:
    let
      stickTop = top + textHeight * 2 + min(rows, (badges.len + columns - 1) div columns) * cellHeight + margin
      size = min(150, max(20, footer - meterReserve - stickTop - textHeight * 4 - margin))
    if sideMeters:
      meterTop = stickTop + textHeight
      meterLeft = width div 2
    for stickIndex, stick in settings.sticks:
      let
        left = margin + stickIndex * (width - margin * 2) div settings.sticks.len
        half = size div 2
      result.text(left, stickTop, stick.label, White, scale)
      result.rect(left, stickTop + textHeight, size, size, Gray)
      result.rect(left + half, stickTop + textHeight, 1, size, White)
      result.rect(left, stickTop + textHeight + half, size, 1, White)
      for device in devices:
        if device.name == stick.device:
          let
            xAxis = device.axis(stick.x)
            yAxis = device.axis(stick.y)
            x = int((xAxis.axisPosition() + 1) * float(size - 1) / 2)
            y = int((yAxis.axisPosition() + 1) * float(size - 1) / 2)
            values = &"X {xAxis.value} Y {yAxis.value}"
          result.rect(left + x - 3, stickTop + textHeight + y - 3, 7, 7, Cyan)
          result.text(left, stickTop + textHeight + size + 5, values, Green, max(1, scale - 1))
      if settings.gamepad == "paddy":
        let
          xValue = monitor.axisPosition(stick.device, GamepadLStickX)
          yValue = monitor.axisPosition(stick.device, GamepadLStickY)
          x = int((xValue + 1) * float(size - 1) / 2)
          y = int((1 - yValue) * float(size - 1) / 2)
          values = &"MAPPED X {xValue:.2f} Y {yValue:.2f}"
        result.rect(left + x - 2, stickTop + textHeight + y - 2, 5, 5, White)
        result.text(left, stickTop + textHeight + size + 5 + textHeight, values, White, max(1, scale - 1))
        result.text(left + size + 12, stickTop + textHeight, "WHITE: MAPPED", White, max(1, scale - 1))
        result.text(left + size + 12, stickTop + textHeight * 2, "CYAN: RAW", Cyan, max(1, scale - 1))
  let
    summary = &"SEEN {seen}/{index} - TONES {tones}" &
      (if settings.gamepad == "paddy": " - PADS " & $monitor.pads.len else: "")
    instructions = if index > columns * rows: "MORE CONTROLS IN SSH LOG"
      elif settings.displayBackend() == "x11": "START/ENTER: TONE - SELECT+START 2S: EXIT"
      else: "START: TONE - HOLD SELECT+START 2S: EXIT"
    outputStatus = if settings.muted: "MUTED"
      elif levels != nil and levels.outputError.len > 0: "UNAVAILABLE"
      else: ""
    micStatus = if not settings.microphoneEnabled: "OFF"
      elif levels != nil and levels.microphoneError.len > 0: "UNAVAILABLE"
      else: ""
  result.drawMeter("SPEAKER OUTPUT", outputStatus,
    if levels == nil: 0.0 else: levels.outputPeak, meterLeft, meterTop, width - meterLeft - margin, scale)
  result.drawMeter("MIC INPUT", micStatus,
    if levels == nil: 0.0 else: levels.microphonePeak,
    meterLeft, meterTop + textHeight * 2, width - meterLeft - margin, scale)
  result.text(margin, footer, summary, Green, scale)
  result.text(margin, footer + textHeight, instructions, White, scale)
  result.text(margin, footer + textHeight * 2, "TOP: COLORS - BOTTOM: GRAY - MOVING MARKER", White, scale)

proc drawTouch(settings: Settings, state: TouchState, trace: TouchTrace,
    width, height, tick: int): Canvas =
  ## Draw the lower-screen touch targets, trails and current contacts.
  result = newCanvas(width, height)
  result.fill(Background)
  let
    scale = max(1, min(width div 340, height div 240))
    margin = max(12, width div 64)
    positions = targets(width, height)
  for x in countup(0, width - 1, max(1, width div 16)):
    result.rect(x, 0, 1, height, Gray)
  for y in countup(0, height - 1, max(1, height div 12)):
    result.rect(0, y, width, 1, Gray)
  for sample in trace.samples:
    result.rect(sample.x - 1, sample.y - 1, 3, 3, Cyan)
  for index, point in positions:
    let color = if trace.tested[index]: Green else: White
    result.rect(point.x - 12, point.y - 1, 25, 3, color)
    result.rect(point.x - 1, point.y - 12, 3, 25, color)
  var
    active = 0
    tested = 0
  for value in trace.tested:
    if value: inc tested
  for contact in state.contacts:
    if contact.active:
      let
        point = state.touchPoint(contact, width, height, 0)
        label = &"ID {contact.id} X {point.x} Y {point.y}"
      result.rect(point.x - 7, point.y - 7, 15, 15, Green)
      result.text(margin, height - 65 - active * 9 * scale, label, Cyan, scale)
      inc active
  let summary = &"TOUCHES {active} - TARGETS {tested}/9"
  result.text(margin, height div 6, settings.title & " - TOUCH SCREEN", White, scale)
  result.text(margin, height div 6 + 12 * scale, "DRAW AND TOUCH ALL NINE CROSSES - X: CLEAR", White, scale)
  result.text(margin, height div 6 + 24 * scale, summary, Green, scale)
  if not state.enabled:
    result.text(margin, height div 2, "NO TOUCH DEVICE SELECTED", White, scale)
  result.rect(4 + tick mod max(1, width - 20), height - 6, 12, 4, Cyan)

proc pressed(devices: seq[InputDevice], code: uint16): bool =
  for device in devices:
    for control in device.controls:
      if control.kind == EventKey and control.code == code and control.value != 0:
        return true

proc namedPressed(settings: Settings, devices: seq[InputDevice], monitor: GamepadMonitor,
    name: string, fallback: uint16): bool =
  if settings.bindings.len == 0:
    return devices.pressed(fallback)
  for binding in settings.bindings:
    if binding.label == name:
      if settings.gamepad == "paddy" and binding.usesPaddy():
        return monitor.active(binding)
      return binding.active(devices)

proc freshPress(settings: Settings, monitor: GamepadMonitor, label: string): bool =
  for binding in settings.bindings:
    if binding.label == label:
      return monitor.freshPress(binding)

proc bindingPress(settings: Settings, device: InputDevice, event: InputEvent, label: string): bool =
  for binding in settings.bindings:
    if binding.label == label and binding.device == device.name:
      return event.tonePress(binding.code, false)

proc isTone(settings: Settings, device: InputDevice, event: InputEvent): bool =
  if settings.bindings.len == 0:
    return event.tonePress(uint16(settings.toneKey), false)
  settings.bindingPress(device, event, "START")

proc calibrate(settings: var Settings, devices: seq[InputDevice], fb: Display) =
  var labels = @["UP", "DOWN", "LEFT", "RIGHT", "A", "B", "X", "Y", "L", "R", "SELECT", "START", "MENU", "VOL-", "VOL+", "L2", "R2"]
  if settings.touchName.len > 0:
    labels.add "BACK"
  let started = getMonoTime()
  var
    index = 0
    waitingRelease = false
    candidate: Binding
    message = "PRESS THEN RELEASE EACH BUTTON"
  while index < labels.len and not stopping:
    if not fb.poll():
      stopping = true
      break
    if (getMonoTime() - started).inSeconds >= settings.seconds:
      raise newException(IOError, "Calibration timed out; profile was not changed")
    var alreadyMapped = false
    for binding in settings.bindings:
      if binding.label == labels[index]:
        alreadyMapped = true
    if alreadyMapped:
      inc index
      continue
    for device in devices:
      if device.touch.enabled:
        continue
      for event in device.readEvents():
        if waitingRelease:
          continue
        var direction = 0'i32
        if event.kind == EventKey and event.value == 1:
          direction = 1
        elif event.kind == EventAbsolute:
          for control in device.controls:
            if control.kind == event.kind and control.code == event.code:
              var sampled = control
              sampled.value = event.value
              direction = sampled.axisDirection()
        if direction != 0:
          candidate = Binding(label: labels[index], device: device.name,
            kind: event.kind, code: event.code, value: direction)
          var duplicate = false
          for binding in settings.bindings:
            if binding.device == candidate.device and binding.kind == candidate.kind and
                binding.code == candidate.code and binding.value == candidate.value:
              duplicate = true
              message = "ALREADY MAPPED TO " & binding.label
          if not duplicate:
            waitingRelease = true
            message = "RELEASE " & labels[index]
    if waitingRelease and not candidate.active(devices):
      settings.bindings.add candidate
      echo "MAPPED ", candidate.label, " device=", candidate.device,
        " type=", candidate.kind, " code=", candidate.code, " direction=", candidate.value
      inc index
      waitingRelease = false
      message = "PRESS THEN RELEASE EACH BUTTON"
    if index < labels.len:
      var canvas = testPattern(fb.width, fb.height, index * 20)
      let scale = max(1, min(fb.width div 240, fb.height div 160))
      canvas.text(20, fb.height div 4, "MAP BUTTONS - " & settings.title, White, max(1, scale - 1))
      canvas.text(20, fb.height div 4 + 50, "PRESS " & labels[index], Cyan, scale * 2)
      canvas.text(20, fb.height div 4 + 120, message, White, max(1, scale - 1))
      canvas.text(20, fb.height div 4 + 155, $(index + 1) & "/" & $labels.len, Green, scale)
      fb.present(canvas)
    sleep(40)
  if stopping:
    return
  var profile = %*{
    "title": settings.title, "framebuffer": settings.framebuffer,
    "display": settings.display, "drmDevice": settings.drmDevice,
    "outputs": settings.outputs, "touchName": settings.touchName,
    "touchRotation": settings.touchRotation, "sticks": newJArray(),
    "audioDevice": settings.audioDevice, "microphoneGainDb": settings.microphoneGainDb,
    "inputNames": settings.inputNames,
    "rotation": settings.rotation, "toneKey": settings.toneKey,
    "bindings": newJArray()
  }
  for stick in settings.sticks:
    profile["sticks"].add %*{"label": stick.label, "device": stick.device,
      "x": int(stick.x), "y": int(stick.y)}
  for binding in settings.bindings:
    profile["bindings"].add %*{"label": binding.label, "device": binding.device,
      "kind": int(binding.kind), "code": int(binding.code), "value": int(binding.value)}
    if binding.label == "START":
      profile["toneKey"] = %int(binding.code)
  let temporary = settings.saveProfile & ".pending"
  writeFile(temporary, profile.pretty() & "\n")
  moveFile(temporary, settings.saveProfile)
  for device in devices:
    for control in device.controls.mitems:
      control.seen = false
      control.negativeSeen = false
      control.positiveSeen = false
  echo "Calibration saved; starting button and sound test"

proc main() =
  var settings = parseSettings(commandLineParams(), detectDevice())
  if settings.command == "help":
    stdout.write(Help)
    return
  if settings.preview.len > 0:
    let dual = settings.outputs.len > 1
    draw(settings, @[], if dual: 1024 else: 720, if dual: 768 else: 480, 64, 0).savePpm(settings.preview)
    if dual:
      let parts = splitFile(settings.preview)
      drawTouch(settings, TouchState(), TouchTrace(), 1024, 768, 64).
        savePpm(parts.dir / (parts.name & "-touch" & parts.ext))
    return
  posix.signal(SIGINT, stopHandler)
  posix.signal(SIGTERM, stopHandler)
  if settings.command == "audio":
    if settings.muted: return
    let audio = AudioTest(device: settings.audioDevice)
    defer: audio.close()
    audio.play()
    while audio.completed == 0 and not stopping:
      audio.poll()
      sleep(20)
    return
  var
    fb: Display
    devices: seq[InputDevice]
  defer:
    for device in devices:
      device.close()
  if settings.command != "input":
    fb = openDisplay(settings)
  defer:
    if fb != nil:
      fb.close()
  if fb != nil:
    for index in 0 ..< fb.count():
      echo "Display ", index + 1, ": ", fb.describe(index)
  let paths = if settings.inputDevices.len > 0: settings.inputDevices else: inputPaths(settings.inputNames)
  for path in paths:
    let device = openInput(path)
    devices.add device
    echo device.describe()
    if settings.command == "info":
      for control in device.controls:
        echo "  type=", control.kind, " code=", control.code,
          " value=", control.value, " min=", control.minimum, " max=", control.maximum
      if device.touch.enabled:
        var activeTouches = 0
        for contact in device.touch.contacts:
          if contact.active: inc activeTouches
        echo "  Touch slots=", device.touch.contacts.len, " active=", activeTouches
  if settings.command == "info":
    echo "ALSA device: ", settings.audioDevice
    echo "Tone key: ", settings.toneKey
    if settings.gamepad == "paddy":
      initGamepads()
      defer: closeGamepads()
      for pad in pollGamepads():
        echo "PADDY id=", pad.id, " name=", pad.name
    return
  if devices.len == 0 and (fb == nil or settings.displayBackend() != "x11"):
    raise newException(IOError, "No input devices selected; use --input:/dev/input/eventN")
  if settings.command == "calibrate":
    settings.calibrate(devices, fb)
    if stopping:
      return
    settings.command = "test"
  if settings.audioDevice != "default" and getEnv("ALSOFT_CONF").len == 0 and
      fileExists("/etc/mono-retro/alsoft.conf"):
    putEnv("ALSOFT_CONF", "/etc/mono-retro/alsoft.conf")
  let audio = if settings.command == "test":
    newHardwareAudio(settings.muted, settings.microphoneEnabled,
      gainDb = settings.microphoneGainDb) else: nil
  defer: audio.close()
  let started = getMonoTime()
  var
    monitor: GamepadMonitor
    tick = 0
    toneCount = 0
    comboStarted: MonoTime
    comboHeld = false
    trace: TouchTrace
    lastDraw: MonoTime
  if settings.gamepad == "paddy":
    initGamepads()
  defer:
    if settings.gamepad == "paddy": closeGamepads()
  while not stopping and (getMonoTime() - started).inSeconds < settings.seconds:
    if fb != nil and not fb.poll(): break
    if settings.command == "test" and fb != nil and fb.window().buttonPressed[KeyEnter]:
      audio.play()
      inc toneCount
    if settings.gamepad == "paddy": monitor.poll()
    for device in devices:
      for event in device.readEvents():
        if event.kind != EventSync:
          echo "RAW ", device.name, " type=", event.kind, " code=", event.code, " value=", event.value
        if settings.gamepad == "raw" and settings.bindingPress(device, event, "X"):
          trace = TouchTrace()
        if settings.gamepad == "raw" and settings.command == "test" and settings.isTone(device, event) and
            not settings.namedPressed(devices, monitor, "SELECT", 314):
          audio.play()
          inc toneCount
    if settings.gamepad == "paddy":
      if settings.freshPress(monitor, "X"): trace = TouchTrace()
      if settings.command == "test" and settings.freshPress(monitor, "START") and
          not settings.namedPressed(devices, monitor, "SELECT", 314):
        audio.play()
        inc toneCount
    if settings.namedPressed(devices, monitor, "SELECT", 314) and
        settings.namedPressed(devices, monitor, "START", 315):
      if not comboHeld:
        comboStarted = getMonoTime()
        comboHeld = true
      elif (getMonoTime() - comboStarted).inMilliseconds >= 2000:
        echo "Exit: Select+Start held for two seconds"
        break
    else:
      comboHeld = false
    if fb != nil and (getMonoTime() - lastDraw).inMilliseconds >= 80:
      lastDraw = getMonoTime()
      audio.poll()
      fb.present(draw(settings, devices, fb.width, fb.height, tick,
        if audio == nil: 0 else: audio.completed, monitor, audio))
      if fb.count() > 1:
        let state = fb.touch
        trace.observe(state, fb.width(1), fb.height(1), 0)
        fb.touch.samples.setLen(0)
        fb.present(drawTouch(settings, state, trace, fb.width(1), fb.height(1), tick), 1)
      inc tick
    sleep(8)
  echo "Completed tone playbacks: ", (if audio == nil: 0 else: audio.completed), "; requests: ", toneCount
  for device in devices:
    for control in device.controls:
      if control.seen:
        echo "SEEN ", device.name, " type=", control.kind, " code=", control.code

when isMainModule:
  main()
