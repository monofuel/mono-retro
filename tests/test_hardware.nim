import
  std/[json],
  retro/[audio, framebuffer, input, pattern, settings]

block:
  let
    red = Bitfield(offset: 11, length: 5)
    green = Bitfield(offset: 5, length: 6)
    blue = Bitfield(offset: 0, length: 5)
  doAssert packPixel(White, red, green, blue, Bitfield()) == 0xffff
  doAssert packPixel(0xff0000, red, green, blue, Bitfield()) == 0xf800
  doAssert packPixel(0x00ff00, red, green, blue, Bitfield()) == 0x07e0
  doAssert packPixel(0x0000ff, red, green, blue, Bitfield()) == 0x001f
  doAssert packPixel(0x123456, Bitfield(offset: 0, length: 8),
    Bitfield(offset: 8, length: 8), Bitfield(offset: 16, length: 8),
    Bitfield(offset: 24, length: 8)) == 0xff563412'u32

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
  doAssert canvas.pixels == @[White, White, 0'u32, 0, White, White, 0, 0, 0, 0, 0, 0]
  let pattern = testPattern(720, 480, 5)
  doAssert pattern.pixels.len == 720 * 480
  doAssert pattern.pixels[0] == White
  doAssert pattern.pixels[30 * 720 + 680] == Black

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
