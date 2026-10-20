import
  std/[json, monotimes, os, posix, strformat, times],
  retro/[audio, framebuffer, input, pattern, settings]

const
  Help = """Usage: hwtest [test|info|input|audio|calibrate] [options]
  --profile:PATH    Device JSON profile
  --fb:PATH         Framebuffer (default /dev/fb0)
  --input:PATH      Input device; repeat for multiple devices
  --pcm:NAME        ALSA PCM (default default)
  --rotate:DEGREES  0, 90, 180, 270
  --seconds:N       Test duration, 1-3600 (default 300)
  --tone-key:N      Fresh key press that plays sound (default 315 / Start)
  --save-profile:PATH  Calibration output profile
  --preview:PATH    Render a PPM preview without accessing hardware

Test mode never plays sound automatically. Start plays a short left/right tone.
Hold Select+Start for two seconds to exit, or use Ctrl+C. Input is observed without an exclusive grab.
Framebuffer bytes and offsets are restored on normal exit, SIGINT and SIGTERM.
"""

var stopping = false

proc stopHandler(signal: cint) {.noconv.} =
  stopping = true

proc draw(settings: Settings, devices: seq[InputDevice], width, height, tick, tones: int): Canvas =
  result = testPattern(width, height, tick)
  let
    margin = max(8, width div 60)
    scale = max(1, min(width div 300, height div 200))
    textHeight = 9 * scale
    top = max(20, height div 5) + margin
    title = "MONO RETRO - " & settings.title
  result.text(margin, top, title, White, scale)
  result.text(margin, top + textHeight, "PRESS ALL BUTTONS - GREEN MEANS SEEN", Cyan, scale)
  var
    index = 0
    seen = 0
  let
    columns = max(2, width div (10 * 6 * scale))
    cellWidth = (width - margin * 2) div columns
    cellHeight = textHeight + 6
    rows = max(1, (height - top - textHeight * 5 - 28) div cellHeight)
  var badges: seq[tuple[label: string, active, seen: bool]]
  if settings.bindings.len > 0:
    for binding in settings.bindings:
      badges.add (binding.label, binding.active(devices), binding.observed(devices))
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
  let
    footer = height - 28 - textHeight * 3
    summary = &"SEEN {seen}/{index} - TONES {tones}"
    instructions = if index > columns * rows: "MORE CONTROLS IN SSH LOG" else: "START: TONE - HOLD SELECT+START 2S: EXIT"
  result.text(margin, footer, summary, Green, scale)
  result.text(margin, footer + textHeight, instructions, White, scale)
  result.text(margin, footer + textHeight * 2, "TOP: COLORS - BOTTOM: GRAY - MOVING MARKER", White, scale)

proc pressed(devices: seq[InputDevice], code: uint16): bool =
  for device in devices:
    for control in device.controls:
      if control.kind == EventKey and control.code == code and control.value != 0:
        return true

proc namedPressed(settings: Settings, devices: seq[InputDevice], name: string, fallback: uint16): bool =
  if settings.bindings.len == 0:
    return devices.pressed(fallback)
  for binding in settings.bindings:
    if binding.label == name:
      return binding.active(devices)

proc isTone(settings: Settings, device: InputDevice, event: InputEvent): bool =
  if settings.bindings.len == 0:
    return event.tonePress(uint16(settings.toneKey), false)
  for binding in settings.bindings:
    if binding.label == "START" and binding.device == device.name:
      return event.tonePress(binding.code, false)

proc calibrate(settings: var Settings, devices: seq[InputDevice], fb: Framebuffer) =
  const Labels = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B", "X", "Y", "L", "R", "SELECT", "START", "MENU", "VOL-", "VOL+", "L2", "R2"]
  let started = getMonoTime()
  var
    index = 0
    waitingRelease = false
    candidate: Binding
    message = "PRESS THEN RELEASE EACH BUTTON"
  while index < Labels.len and not stopping:
    if (getMonoTime() - started).inSeconds >= settings.seconds:
      raise newException(IOError, "Calibration timed out; profile was not changed")
    var alreadyMapped = false
    for binding in settings.bindings:
      if binding.label == Labels[index]:
        alreadyMapped = true
    if alreadyMapped:
      inc index
      continue
    for device in devices:
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
          candidate = Binding(label: Labels[index], device: device.name,
            kind: event.kind, code: event.code, value: direction)
          var duplicate = false
          for binding in settings.bindings:
            if binding.device == candidate.device and binding.kind == candidate.kind and
                binding.code == candidate.code and binding.value == candidate.value:
              duplicate = true
              message = "ALREADY MAPPED TO " & binding.label
          if not duplicate:
            waitingRelease = true
            message = "RELEASE " & Labels[index]
    if waitingRelease and not candidate.active(devices):
      settings.bindings.add candidate
      echo "MAPPED ", candidate.label, " device=", candidate.device,
        " type=", candidate.kind, " code=", candidate.code, " direction=", candidate.value
      inc index
      waitingRelease = false
      message = "PRESS THEN RELEASE EACH BUTTON"
    if index < Labels.len:
      var canvas = testPattern(fb.width, fb.height, index * 20)
      let scale = max(1, min(fb.width div 240, fb.height div 160))
      canvas.text(20, fb.height div 4, "MAP BUTTONS - " & settings.title, White, max(1, scale - 1))
      canvas.text(20, fb.height div 4 + 50, "PRESS " & Labels[index], Cyan, scale * 2)
      canvas.text(20, fb.height div 4 + 120, message, White, max(1, scale - 1))
      canvas.text(20, fb.height div 4 + 155, $(index + 1) & "/" & $Labels.len, Green, scale)
      fb.present(canvas)
    sleep(40)
  if stopping:
    return
  var profile = %*{
    "title": settings.title, "framebuffer": settings.framebuffer,
    "audioDevice": settings.audioDevice, "inputNames": settings.inputNames,
    "rotation": settings.rotation, "toneKey": settings.toneKey,
    "bindings": newJArray()
  }
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
  var settings = parseSettings(commandLineParams())
  if settings.command == "help":
    stdout.write(Help)
    return
  if settings.preview.len > 0:
    draw(settings, @[], 720, 480, 64, 0).savePpm(settings.preview)
    return
  posix.signal(SIGINT, stopHandler)
  posix.signal(SIGTERM, stopHandler)
  let audio = AudioTest(device: settings.audioDevice)
  defer: audio.close()
  if settings.command == "audio":
    audio.play()
    while audio.completed == 0 and not stopping:
      audio.poll()
      sleep(20)
    return
  var
    fb: Framebuffer
    devices: seq[InputDevice]
  defer:
    for device in devices:
      device.close()
  if settings.command != "input":
    fb = openFramebuffer(settings.framebuffer, settings.rotation)
  defer:
    if fb != nil:
      fb.close()
  if fb != nil:
    echo "Framebuffer: ", fb.describe()
  let paths = if settings.inputDevices.len > 0: settings.inputDevices else: inputPaths(settings.inputNames)
  for path in paths:
    let device = openInput(path)
    devices.add device
    echo device.describe()
  if settings.command == "info":
    echo "ALSA device: ", settings.audioDevice
    echo "Tone key: ", settings.toneKey
    return
  if devices.len == 0:
    raise newException(IOError, "No input devices selected; use --input:/dev/input/eventN")
  if settings.command == "calibrate":
    settings.calibrate(devices, fb)
    if stopping:
      return
    settings.command = "test"
  let started = getMonoTime()
  var
    tick = 0
    toneCount = 0
    comboStarted: MonoTime
    comboHeld = false
  while not stopping and (getMonoTime() - started).inSeconds < settings.seconds:
    for device in devices:
      for event in device.readEvents():
        echo device.name, " type=", event.kind, " code=", event.code, " value=", event.value
        if settings.command == "test" and settings.isTone(device, event) and
            not settings.namedPressed(devices, "SELECT", 314):
          audio.play()
          inc toneCount
    if settings.namedPressed(devices, "SELECT", 314) and settings.namedPressed(devices, "START", 315):
      if not comboHeld:
        comboStarted = getMonoTime()
        comboHeld = true
      elif (getMonoTime() - comboStarted).inMilliseconds >= 2000:
        echo "Exit: Select+Start held for two seconds"
        break
    else:
      comboHeld = false
    audio.poll()
    if fb != nil:
      fb.present(draw(settings, devices, fb.width, fb.height, tick, audio.completed))
    inc tick
    sleep(80)
  echo "Completed tone playbacks: ", audio.completed, "; requests: ", toneCount
  for device in devices:
    for control in device.controls:
      if control.seen:
        echo "SEEN ", device.name, " type=", control.kind, " code=", control.code

when isMainModule:
  main()
