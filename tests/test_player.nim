import
  std/[math, os, strutils, tempfiles],
  paddy, pixie, windy,
  retro/[anbernic, playerclock, playerinput, playersave, playervideo]

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
      (3, 2, 1, 0, 0), (8, 5, 2, 1, 0), (11, 8, 3, 1, 1), (4, 9, 1, 0, 3)]:
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
