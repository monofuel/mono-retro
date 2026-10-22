import
  std/[json],
  pixie,
  windy/platforms/linux/backends,
  retro/[audio, display, input, pattern, settings, touch]

block:
  var configuration = defaultSettings()
  when HasX11: doAssert configuration.displayBackend() == "x11"
  elif HasFbdev: doAssert configuration.displayBackend() == "fbdev"
  else: doAssert configuration.displayBackend() == "drm"
  configuration.display = "fbdev"
  doAssert configuration.displayBackend() == "fbdev"
  configuration.display = "drm"
  doAssert configuration.displayBackend() == "drm"

block:
  for rotation in [0, 90, 180, 270]:
    var points: seq[tuple[x, y: int]]
    for y in 0..<2:
      for x in 0..<3:
        let point = rotatedPoint(x, y, 3, 2, rotation)
        doAssert point.x >= 0 and point.y >= 0
        doAssert point.x < (if rotation in [90, 270]: 2 else: 3)
        doAssert point.y < (if rotation in [90, 270]: 3 else: 2)
        doAssert point notin points
        points.add point
    doAssert points.len == 6
  doAssert rotatedPoint(0, 0, 3, 2, 90) == (1, 0)
  doAssert rotatedPoint(0, 0, 3, 2, 270) == (0, 2)

block:
  var canvas = newCanvas(4, 3)
  canvas.rect(-1, -1, 3, 3, White)
  doAssert canvas.data[0] == rgbx(255, 255, 255, 255)
  doAssert canvas.data[5] == rgbx(255, 255, 255, 255)
  doAssert canvas.data[2] == rgbx(0, 0, 0, 0)
  doAssert canvas.data[11] == rgbx(0, 0, 0, 0)
  let pattern = testPattern(720, 480, 5)
  doAssert pattern.data.len == 720 * 480
  doAssert pattern.data[0] == rgbx(255, 255, 255, 255)
  doAssert pattern.data[30 * 720 + 680] == rgbx(0, 0, 0, 255)

block:
  var controls = @[
    Control(kind: EventKey, code: 315),
    Control(kind: EventAbsolute, code: 16, minimum: -1, maximum: 1)
  ]
  controls.applyEvent(InputEvent(kind: EventKey, code: 315, value: 1))
  doAssert controls[0].seen and controls[0].value == 1
  controls.applyEvent(InputEvent(kind: EventKey, code: 315, value: 0))
  doAssert controls[0].seen and controls[0].value == 0
  controls.applyEvent(InputEvent(kind: EventAbsolute, code: 16, value: -1))
  doAssert controls[1].seen and controls[1].value == -1
  controls.applyEvent(InputEvent(kind: EventKey, code: 316, value: 1))
  doAssert controls[0].value == 0

block:
  let wave = toneWave()
  doAssert wave[0..<4] == "RIFF"
  doAssert wave[8..<16] == "WAVEfmt "
  doAssert wave[36..<40] == "data"
  let
    settle = int(SettleSeconds * SampleRate)
    tone = int(ToneSeconds * SampleRate)
    gap = int(GapSeconds * SampleRate)
  doAssert wave.len == 44 + (settle * 2 + tone * 2 + gap) * 4
  doAssert wave[22].ord == 2
  var
    leftSound = false
    rightSound = false
  for frame in settle ..< settle + tone:
    let offset = 44 + frame * 4
    doAssert wave[offset + 2] == '\0' and wave[offset + 3] == '\0'
    if wave[offset] != '\0': leftSound = true
  for frame in settle + tone + gap ..< settle + tone * 2 + gap:
    let offset = 44 + frame * 4
    doAssert wave[offset] == '\0' and wave[offset + 1] == '\0'
    if wave[offset + 2] != '\0': rightSound = true
  doAssert leftSound and rightSound
  for index in 44 ..< 44 + settle * 4:
    doAssert wave[index] == '\0'
  for index in wave.len - settle * 4 ..< wave.len:
    doAssert wave[index] == '\0'

block:
  var settings = defaultSettings()
  settings.applyProfile(parseJson("{\"title\":\"TEST\",\"rotation\":90}"))
  doAssert settings.title == "TEST" and settings.rotation == 90
  doAssert settings.audioDevice == "default" and settings.toneKey == 315
  let parsed = parseSettings(@["input", "--input:/dev/input/event7", "--seconds:5"])
  doAssert parsed.command == "input" and parsed.inputDevices == @["/dev/input/event7"]
  doAssert parsed.seconds == 5
  var rejected = false
  try:
    discard parseSettings(@["--rotate:45"])
  except ValueError:
    rejected = true
  doAssert rejected

block:
  doAssert InputEvent(kind: EventKey, code: 315, value: 1).tonePress(315, false)
  doAssert not InputEvent(kind: EventKey, code: 315, value: 2).tonePress(315, false)
  doAssert not InputEvent(kind: EventKey, code: 315, value: 0).tonePress(315, false)
  doAssert not InputEvent(kind: EventKey, code: 315, value: 1).tonePress(315, true)
  doAssert not InputEvent(kind: EventAbsolute, code: 315, value: 1).tonePress(315, false)
  let device = InputDevice(name: "test", controls: @[
    Control(kind: EventAbsolute, code: 16, minimum: -1, maximum: 1)])
  let
    left = Binding(label: "LEFT", device: "test", kind: EventAbsolute, code: 16, value: -1)
    right = Binding(label: "RIGHT", device: "test", kind: EventAbsolute, code: 16, value: 1)
  device.controls.applyEvent(InputEvent(kind: EventAbsolute, code: 16, value: -1))
  doAssert left.active(@[device]) and left.observed(@[device])
  doAssert not right.active(@[device]) and not right.observed(@[device])
  device.controls.applyEvent(InputEvent(kind: EventAbsolute, code: 16, value: 0))
  doAssert not left.active(@[device]) and left.observed(@[device])
  var mapped = defaultSettings()
  mapped.applyProfile(parseJson("{\"bindings\":[{\"label\":\"LEFT\",\"device\":\"test\",\"kind\":3,\"code\":16,\"value\":-1}]}"))
  doAssert mapped.bindings == @[left]

block:
  doAssert identifyDevice("rockchip,rk3568-deep-lp3-v10\0rockchip,rk3568",
    @["ANBERNIC-rk3568-keys"], "", 2) == rgDsPlusDevice
  doAssert identifyDevice("rockchip,rk3568", @[], "", 2) == genericDevice
  doAssert identifyDevice("rockchip,rk3568", @["ANBERNIC-rk3568-keys"], "", 1) == genericDevice
  doAssert identifyDevice("allwinner,h616\0arm,sun50iw9p1",
    @["ANBERNIC-keys"], "720,960", 0) == rgSpDevice
  doAssert identifyDevice("arm,sun50iw9p1", @["ANBERNIC-keys"], "640,480", 0) == genericDevice
  let
    sp = parseSettings(@[], rgSpDevice)
    ds = parseSettings(@[], rgDsPlusDevice)
    overridden = parseSettings(@["--output:DSI-2", "--output:DSI-1", "--pcm:null"], rgDsPlusDevice)
    generic = parseSettings(@["--device:generic"], rgDsPlusDevice)
  doAssert sp.bindings.len == 17 and sp.audioDevice == "mono_retro_test"
  doAssert sp.display == "fbdev"
  doAssert ds.bindings.len == 19 and ds.sticks.len == 1
  doAssert ds.sticks[0].label == "LEFT STICK"
  doAssert ds.display == "drm" and ds.outputs == @["DSI-1", "DSI-2"]
  doAssert ds.touchName == "gt9xx-0"
  doAssert overridden.outputs == @["DSI-2", "DSI-1"] and overridden.audioDevice == "null"
  doAssert generic.bindings.len == 0 and generic.outputs.len == 0
  var
    back: Binding
    menu: Binding
  for binding in ds.bindings:
    if binding.label == "BACK": back = binding
    if binding.label == "MENU": menu = binding
  doAssert back.device == "adc-keys" and back.code == 158
  doAssert menu.device == "ANBERNIC-rk3568-keys" and menu.code == 312

block:
  var controls = @[Control(kind: EventAbsolute, code: 16, minimum: 0, maximum: 1)]
  doAssert controls[0].axisDirection() == 0
  controls.applyEvent(InputEvent(kind: EventAbsolute, code: 16, value: 1))
  doAssert controls[0].axisDirection() == 1 and controls[0].positiveSeen
  controls.applyEvent(InputEvent(kind: EventAbsolute, code: 16, value: 0))
  doAssert controls[0].axisDirection() == 0 and not controls[0].negativeSeen
  controls.applyEvent(InputEvent(kind: EventAbsolute, code: 16, value: -1))
  doAssert controls[0].negativeSeen
  var stick = Control(kind: EventAbsolute, code: 2, minimum: -4096, maximum: 4096, flat: 32)
  doAssert stick.axisPosition() == 0
  stick.value = 20
  doAssert stick.axisPosition() == 20.0 / 4096
  stick.value = -1
  doAssert stick.axisPosition() == -1.0 / 4096
  stick.value = -4096
  doAssert stick.axisPosition() == -1
  stick.value = 9000
  doAssert stick.axisPosition() == 1

block:
  let device = InputDevice(controls: @[
    Control(kind: EventAbsolute, code: SlotCode, minimum: 0, maximum: 15),
    Control(kind: EventAbsolute, code: PositionXCode, minimum: 0, maximum: 1024),
    Control(kind: EventAbsolute, code: PositionYCode, minimum: 0, maximum: 768)])
  device.configureTouch()
  doAssert device.touch.enabled and device.touch.multitouch
  doAssert device.touch.contacts.len == 16
  device.touch.apply(EventAbsolute, SlotCode, 3)
  device.touch.apply(EventAbsolute, TrackingCode, 7)
  device.touch.apply(EventAbsolute, PositionXCode, 1024)
  device.touch.apply(EventAbsolute, PositionYCode, 768)
  doAssert not device.touch.contacts[3].active
  device.touch.apply(EventSync, 0, 0)
  doAssert device.touch.contacts[3].active and not device.touch.contacts[0].active
  doAssert device.touch.touchPoint(device.touch.contacts[3], 1024, 768, 0) == (1023, 767)
  device.touch.apply(EventAbsolute, PositionXCode, 512)
  doAssert device.touch.contacts[3].x == 1024
  device.touch.apply(EventSync, 0, 0)
  doAssert device.touch.contacts[3].x == 512
  device.touch.apply(EventAbsolute, SlotCode, 0)
  device.touch.apply(EventAbsolute, TrackingCode, 8)
  device.touch.apply(EventAbsolute, PositionXCode, 0)
  device.touch.apply(EventAbsolute, PositionYCode, 0)
  device.touch.apply(EventSync, 0, 0)
  doAssert device.touch.contacts[0].active and device.touch.contacts[3].active
  device.touch.apply(EventAbsolute, SlotCode, 3)
  device.touch.apply(EventAbsolute, TrackingCode, -1)
  device.touch.apply(EventSync, 0, 0)
  doAssert not device.touch.contacts[3].active and device.touch.contacts[0].active
  var trace: TouchTrace
  trace.observe(device.touch, 1024, 768, 0)
  doAssert trace.samples.len > 0
  device.touch.clear()
  doAssert device.touch.samples.len == 0
  for contact in device.touch.contacts:
    doAssert not contact.active

block:
  let device = InputDevice(controls: @[
    Control(kind: EventKey, code: TouchCode),
    Control(kind: EventAbsolute, code: 0, minimum: 100, maximum: 1100),
    Control(kind: EventAbsolute, code: 1, minimum: 50, maximum: 850)])
  device.configureTouch()
  doAssert device.touch.enabled and not device.touch.multitouch
  device.touch.apply(EventKey, TouchCode, 1)
  device.touch.apply(EventAbsolute, 0, 100)
  device.touch.apply(EventAbsolute, 1, 50)
  device.touch.apply(EventSync, 0, 0)
  let contact = device.touch.contacts[0]
  doAssert device.touch.touchPoint(contact, 1024, 768, 0) == (0, 0)
  doAssert device.touch.touchPoint(contact, 1024, 768, 90) == (1023, 0)
  doAssert device.touch.touchPoint(contact, 1024, 768, 180) == (1023, 767)
  doAssert device.touch.touchPoint(contact, 1024, 768, 270) == (0, 767)
  device.touch.apply(EventKey, TouchCode, 0)
  device.touch.apply(EventSync, 0, 0)
  doAssert not device.touch.contacts[0].active
  var trace: TouchTrace
  trace.observe(device.touch, 1024, 768, 0)
  doAssert trace.samples.len > 0
