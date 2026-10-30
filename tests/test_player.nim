import
  std/[math, os, strutils, tempfiles],
  paddy, pixie, windy,
  retro/[anbernic, playerclock, playerinput, playersave, playervideo, touch]

block:
  # Native touch must work without a desktop window or desktop property access.
  let
    noWindow: Window = nil
    empty = overlayContact(noWindow, false, 0, [])
    contacts = [touch.TouchContact(id: 1, x: 9, y: 12, active: false),
      touch.TouchContact(id: 2, x: 600, y: 330, active: true),
      touch.TouchContact(id: 3, x: 100, y: 200, active: true)]
    pressed = overlayContact(noWindow, false, 0, contacts)
  doAssert not empty.held and empty.output == 0
  doAssert pressed.held and pressed.output == 1
  doAssert pressed.x == 600 and pressed.y == 330
  doAssert not overlayContact(noWindow, false, 1,
    [touch.TouchContact(id: 2, active: false)]).held

block:
  let
    values = [0xa0123456'u32, 0x7fabcdef'u32, 0x99010203'u32, 0x00456789'u32]
    expected = @[rgbx(0x12, 0x34, 0x56, 255), rgbx(0xab, 0xcd, 0xef, 255),
      rgbx(1, 2, 3, 255), rgbx(0x45, 0x67, 0x89, 255)]
  var bytes: array[19, byte]
  copyMem(addr bytes[1], unsafeAddr values[0], 8)
  copyMem(addr bytes[10], unsafeAddr values[2], 8)
  doAssert copyFrame(nil, addr bytes[1], 2, 2, 9, PixelXrgb8888).data == expected

block:
  var pixels = [0x00ff0000'u32, 0x0000ff00, 0xdeadbeef'u32, 0x000000ff, 0x00ffffff, 0xdeadbeef'u32]
  let image = copyFrame(nil, addr pixels[0], 2, 2, 12, PixelXrgb8888)
  doAssert image.data == @[rgbx(255, 0, 0, 255), rgbx(0, 255, 0, 255),
    rgbx(0, 0, 255, 255), rgbx(255, 255, 255, 255)]
  pixels[0] = 0
  doAssert image.data[0].r == 255
  doAssert copyFrame(image, nil, 0, 0, 0, PixelXrgb8888) == image
  let canvas = fitFrame(image, nil, 8, 4)
  doAssert canvas.data[0] == rgbx(0, 0, 0, 255)
  doAssert canvas.data[2] == image.data[0]
  doAssert canvas.data[5] == image.data[1]
  doAssert canvas.data[2 + 3 * 8] == image.data[2]
  doAssert fitFrame(image, canvas, 1, 1).data[0] == image.data[0]
  for format in [PixelRgb1555, PixelRgb565]:
    var values = if format == PixelRgb565: [0xf800'u16, 0x07e0, 0x001f]
      else: [0x7c00'u16, 0x03e0, 0x001f]
    let converted = copyFrame(nil, addr values[0], 3, 1, 6, format)
    doAssert converted.data == @[rgbx(255, 0, 0, 255), rgbx(0, 255, 0, 255), rgbx(0, 0, 255, 255)]
  var rejected = false
  try: discard copyFrame(nil, addr pixels[0], 2, 2, 3, PixelXrgb8888)
  except ValueError: rejected = true
  doAssert rejected

block:
  let source = newImage(3, 2)
  source.data = @[rgbx(255, 0, 0, 255), rgbx(0, 255, 0, 255), rgbx(0, 0, 255, 255),
    rgbx(255, 255, 255, 255), rgbx(128, 128, 128, 255), rgbx(255, 255, 0, 255)]
  var canvas: Image
  for (width, height, scale, left, top) in [
      (3, 2, 1, 0, 0), (8, 5, 2, 1, 0), (11, 8, 3, 1, 1),
      (14, 11, 4, 1, 1), (17, 13, 5, 1, 1), (4, 9, 1, 0, 3),
      (1, 1, 1, -1, 0), (1, 5, 1, -1, 1), (7, 1, 1, 2, 0)]:
    canvas = fitFrame(source, canvas, width, height)
    for y in 0 ..< height:
      for x in 0 ..< width:
        let expected = if x >= left and x < left + 3 * scale and
            y >= top and y < top + 2 * scale:
          source.data[((y - top) div scale) * 3 + (x - left) div scale]
        else: rgbx(0, 0, 0, 255)
        doAssert canvas.data[y * width + x] == expected
  let clipped = fitFrame(source, canvas, 1, 2)
  doAssert clipped.data == @[source.data[1], source.data[4]]
  canvas = fitFrame(source, canvas, 8, 5)
  source.fill(rgbx(12, 34, 56, 255))
  doAssert fitFrame(source, canvas, 8, 5) == canvas
  doAssert canvas.data[1] == source.data[0]
  doAssert canvas.data[0] == rgbx(0, 0, 0, 255)
  let narrow = newImage(1, 2)
  narrow.fill(rgbx(56, 78, 90, 255))
  canvas = fitFrame(narrow, canvas, 8, 5)
  doAssert canvas[1, 1] == rgbx(0, 0, 0, 255)
  doAssert canvas[3, 1] == narrow[0, 0]
  doAssert fitFrame(nil, canvas, 8, 5).isOneColor()

block:
  doAssert keyboardButtons({KeyX, KeyUp, KeyEnter}) == ((1'u16 shl 8) or (1'u16 shl 4) or (1'u16 shl 3))
  doAssert keyboardButtons({}) == 0
  let pad = Gamepad(id: 2, buttons: (1'u64 shl GamepadB.int) or (1'u64 shl GamepadR1.int))
  doAssert gamepadButtons(@[pad]) == ((1'u16 shl 8) or (1'u16 shl 11))
  doAssert gamepadButtons(@[pad, Gamepad(id: 1)]) == 0
  doAssert gamepadButtons(@[]) == 0
  let handheld = mapAnbernic(Gamepad(id: 0, name: "ANBERNIC-rk3568-keys",
    buttons: (1'u64 shl GamepadA.int), pressed: (1'u64 shl GamepadSelect.int)))
  doAssert gamepadButtons(@[handheld]) == 1'u16 shl 8
  doAssert firstGamepad(@[handheld]).buttonPressed(GamepadL2)
  doAssert firstGamepad(@[]).buttons == 0

block:
  for (button, retroId) in [(GamepadA, 0), (GamepadB, 8), (GamepadX, 1), (GamepadY, 9)]:
    doAssert gamepadButtons(@[Gamepad(id: 0, buttons: 1'u64 shl button.int)]) == 1'u16 shl retroId
  for name in ["ANBERNIC-keys", "ANBERNIC-rk3568-keys"]:
    for (button, retroId) in [(GamepadA, 8), (GamepadB, 0), (GamepadC, 1), (GamepadY, 9)]:
      let pad = mapAnbernic(Gamepad(id: 0, name: name, buttons: 1'u64 shl button.int))
      doAssert gamepadButtons(@[pad]) == 1'u16 shl retroId
  var pad = Gamepad(id: 0)
  for (x, up, expected) in [
      (0'f32, 0'f32, 0'u16), (0.49'f32, -0.49'f32, 0'u16),
      (-0.5'f32, 0'f32, 1'u16 shl 6), (0.5'f32, 0'f32, 1'u16 shl 7),
      (0'f32, 0.5'f32, 1'u16 shl 4), (0'f32, -0.5'f32, 1'u16 shl 5),
      (-1'f32, 1'f32, (1'u16 shl 6) or (1'u16 shl 4)),
      (1'f32, 1'f32, (1'u16 shl 7) or (1'u16 shl 4)),
      (-1'f32, -1'f32, (1'u16 shl 6) or (1'u16 shl 5)),
      (1'f32, -1'f32, (1'u16 shl 7) or (1'u16 shl 5))]:
    pad.axes[GamepadLStickX.int] = x
    when defined(linux): pad.axes[GamepadLStickY.int] = -up
    else: pad.axes[GamepadLStickY.int] = up
    doAssert gamepadButtons(@[pad]) == expected
  pad.buttons = (1'u64 shl GamepadLeft.int) or (1'u64 shl GamepadUp.int)
  doAssert gamepadButtons(@[pad]) == ((1'u16 shl 6) or (1'u16 shl 4))
  pad = Gamepad(id: 0)
  doAssert gamepadButtons(@[pad]) == 0
  pad.axes[GamepadRStickX.int] = 1
  pad.axes[GamepadRStickY.int] = 1
  doAssert gamepadButtons(@[pad]) == 0
  pad = Gamepad(id: 0, name: "ANBERNIC-rk3568-keys")
  pad.axes[GamepadRStickX.int] = -1
  doAssert gamepadButtons(@[pad.mapAnbernic()]) == 1'u16 shl 4
  doAssert gamepadButtons(@[]) == 0

block:
  var clock = newFrameClock(59.7275, 100)
  doAssert clock.period == int64(1_000_000_000.0 / 59.7275)
  clock.advance(100)
  doAssert clock.deadline == 100 + clock.period
  let late = clock.deadline + clock.period * 4
  clock.advance(late)
  doAssert clock.deadline == late
  clock.advance(late + clock.period div 4)
  doAssert clock.deadline == late + clock.period
  clock.reset(500)
  doAssert clock.deadline == 500

block:
  var clock = newFrameClock(60, 0)
  let period = clock.period
  clock.advance(period + period div 2)
  doAssert clock.deadline == period
  clock.advance(period * 2)
  doAssert clock.deadline == period * 2
  clock.advance(period * 7)
  doAssert clock.deadline == period * 7
  clock.reset(0)
  clock.advance(period * 3)
  doAssert clock.deadline == period
  clock.advance(period * 4 + 1)
  doAssert clock.deadline == period * 4 + 1
  for fps in [0.0, -1.0, Inf, NaN]:
    var rejected = false
    try: discard newFrameClock(fps, 0)
    except ValueError: rejected = true
    doAssert rejected

block:
  let
    directory = createTempDir("player-save-", "")
    path = directory / "game.srm"
  defer: removeDir(directory)
  writeSave(path, "first\0save")
  writeSave(path, "second\0save")
  doAssert readFile(path) == "second\0save"
  let occupied = directory / "occupied"
  createDir(occupied)
  writeFile(occupied / "original", "untouched")
  var rejected = false
  try: writeSave(occupied, "replacement")
  except OSError: rejected = true
  doAssert rejected
  doAssert readFile(occupied / "original") == "untouched"
  var temporary = false
  for kind, file in walkDir(directory):
    if file.extractFilename.startsWith(".player-save-"): temporary = true
  doAssert not temporary
