import
  pixie,
  retro/[libretro, playerds, playervideo, touch]

doAssert parseDsLayout("combined") == CombinedDs
doAssert parseDsLayout("separate") == SeparateDs
block:
  let source = newImage(2, 4)
  source.fill(rgbx(255, 0, 0, 255))
  let
    top = dsScreen(source, nil, 0, 2, 2)
    bottom = dsScreen(source, nil, 1, 2, 2)
  doAssert not sameDsScreen(source, nil, 0, 2, 2)
  doAssert not sameDsScreen(source, newImage(1, 1), 0, 2, 2)
  doAssert sameDsScreen(source, top, 0, 2, 2)
  doAssert sameDsScreen(source, bottom, 1, 2, 2)
  source.data[0] = rgbx(0, 255, 0, 255)
  doAssert not sameDsScreen(source, top, 0, 2, 2)
  doAssert sameDsScreen(source, bottom, 1, 2, 2)
  discard dsScreen(source, top, 0, 2, 2)
  doAssert sameDsScreen(source, top, 0, 2, 2)
  source.data[^1] = rgbx(0, 0, 255, 255)
  doAssert not sameDsScreen(source, bottom, 1, 2, 2)
  doAssert sameDsScreen(source, top, 0, 2, 2)

block:
  let profile = selectDualScreen(NoDsLayout, true)
  doAssert profile.layout == SeparateDs
  doAssert profile.panelWidth == 256 and profile.panelHeight == 224
  doAssert profile.desktopScale == 2
  doAssert profile.options == @[("decompbound_dual_screen", "enabled")]
  doAssert profile.topTitle == "Game" and profile.bottomTitle == "Party"
  doAssert selectDualScreen(SeparateDs).options == DsOptions
  doAssert selectDualScreen(NoDsLayout).options.len == 0
  for layout in [CombinedDs, SeparateDs]:
    var rejected = false
    try: discard selectDualScreen(layout, true)
    except ValueError: rejected = true
    doAssert rejected

block:
  var gesture: CompanionGesture
  let inside = dsPointer(SeparateDs, 1, 1024, 768, 149, 69, true, 256, 224)
  doAssert gesture.companionPointer(inside, true).pressed
  doAssert not gesture.companionPointer(PointerInput(), true).pressed
  doAssert not gesture.companionPointer(inside, true).pressed
  discard gesture.companionPointer(PointerInput(), false)
  doAssert gesture.companionPointer(inside, true).pressed

block:
  let image = newImage(256, 448)
  for index in 0 ..< image.data.len:
    image.data[index] = if index < 256 * 224: rgbx(255, 0, 0, 255)
      else: rgbx(0, 0, 255, 255)
  let
    top = dsScreen(image, nil, 0, 256, 224)
    bottom = dsScreen(image, nil, 1, 256, 224)
  doAssert top.width == 256 and top.height == 224
  doAssert top.data[^1] == rgbx(255, 0, 0, 255)
  doAssert bottom.data[0] == rgbx(0, 0, 255, 255)
  let fitted = fitFrame(bottom, nil, 1024, 768)
  doAssert fitted.data[48 * 1024 + 128] == bottom.data[0]
  doAssert fitted.data[47 * 1024 + 128] == rgbx(0, 0, 0, 255)
  doAssert fitted.data[48 * 1024 + 127] == rgbx(0, 0, 0, 255)
  for scale in 2 .. 5:
    let
      width = 256 * scale + 10
      height = 224 * scale + 12
    for (x, y) in [(0, 0), (255, 223), (64, 64), (7, 7)]:
      let pointer = dsPointer(SeparateDs, 1, width, height,
        5 + x * scale, 6 + y * scale, true, 256, 224)
      doAssert pointer.pressed
      doAssert (pointer.x.int + 32767) * 256 div 65534 == x
      doAssert (pointer.y.int + 32767) * 448 div 65534 == y + 224
    doAssert not dsPointer(SeparateDs, 1, width, height, 0, 0, true, 256, 224).pressed
    doAssert not dsPointer(SeparateDs, 0, width, height, 12, 12, true, 256, 224).pressed
  var stylus: DsStylus
  let contact = TouchContact(id: 4, x: 128 + 7 * 3, y: 48 + 7 * 3, active: true)
  let pointer = stylus.nativeDsPointer(@[contact], 1024, 768, 256, 224)
  doAssert pointer.pressed
  doAssert (pointer.x.int + 32767) * 256 div 65534 == 7
  doAssert (pointer.y.int + 32767) * 448 div 65534 == 231
  doAssert not stylus.nativeDsPointer(@[], 1024, 768, 256, 224).pressed
var rejected = false
try: discard parseDsLayout("unknown")
except ValueError: rejected = true
doAssert rejected
let image = newImage(DsWidth, DsHeight * 2)
image.fill(rgbx(255, 0, 0, 255))
for index in DsWidth * DsHeight ..< image.data.len:
  image.data[index] = rgbx(0, 0, 255, 255)
let
  top = dsScreen(image, nil, 0)
  bottom = dsScreen(image, nil, 1)
doAssert top.width == DsWidth and top.height == DsHeight
doAssert top.data[0] == rgbx(255, 0, 0, 255)
doAssert bottom.data[^1] == rgbx(0, 0, 255, 255)
doAssert dsScreen(image, bottom, 0) == bottom
doAssert bottom.data[0] == top.data[0]
rejected = false
try: discard dsScreen(newImage(3, 2), nil, 0)
except ValueError: rejected = true
doAssert rejected
for scale in 1 .. 4:
  let
    combined = dsPointer(CombinedDs, 0, 256 * scale + 10, 384 * scale + 12,
      5 + 123 * scale, 6 + 234 * scale, true)
    separate = dsPointer(SeparateDs, 1, 256 * scale + 10, 192 * scale + 12,
      5 + 123 * scale, 6 + 42 * scale, true)
  doAssert combined == separate and combined.pressed
  doAssert (combined.x.int + 32767) * 256 div 65534 == 123
  doAssert (combined.y.int + 32767) * 384 div 65534 == 234
  doAssert not dsPointer(SeparateDs, 0, 256, 192, 123, 42, true).pressed
  doAssert not dsPointer(CombinedDs, 0, 256, 384, 123, 42, true).pressed
  doAssert not dsPointer(SeparateDs, 1, 256 * scale + 10, 192 * scale + 12, 0, 0, true).pressed
doAssert dsPointer(SeparateDs, 1, 128, 96, 0, 0, true) ==
  dsPointer(SeparateDs, 1, 256, 192, 64, 48, true)
doAssert not dsPointer(SeparateDs, 1, 256, 192, 123, 42, false).pressed
doAssert not dsPointer(SeparateDs, 1, 256, 192, -1, 42, true).pressed

block:
  validateDsDisplay(NoDsLayout, "fbdev", 1)
  validateDsDisplay(CombinedDs, "x11", 0)
  validateDsDisplay(SeparateDs, "x11", 0)
  validateDsDisplay(SeparateDs, "drm", 2)
  for (layout, backend, outputs) in [(CombinedDs, "drm", 2),
      (SeparateDs, "drm", 1), (SeparateDs, "drm", 3), (SeparateDs, "fbdev", 1)]:
    var rejected = false
    try: validateDsDisplay(layout, backend, outputs)
    except ValueError: rejected = true
    doAssert rejected

block:
  var stylus: DsStylus
  let
    first = TouchContact(id: 7, x: 492, y: 168, active: true)
    second = TouchContact(id: 8, x: 800, y: 600, active: true)
    expected = dsPointer(SeparateDs, 1, 1024, 768, 492, 168, true)
  doAssert not stylus.nativeDsPointer(@[], 1024, 768).pressed
  doAssert stylus.nativeDsPointer(@[first], 1024, 768) == expected
  doAssert stylus.nativeDsPointer(@[second, first], 1024, 768) == expected
  var moved = first
  moved.x = 512
  doAssert stylus.nativeDsPointer(@[second, moved], 1024, 768) ==
    dsPointer(SeparateDs, 1, 1024, 768, 512, 168, true)
  doAssert not stylus.nativeDsPointer(@[second], 1024, 768).pressed
  doAssert not stylus.nativeDsPointer(@[], 1024, 768).pressed
  doAssert stylus.nativeDsPointer(@[first], 1024, 768).pressed
  moved.active = false
  doAssert not stylus.nativeDsPointer(@[moved], 1024, 768).pressed
  for (x, y) in [(0, 0), (1023, 0), (0, 767), (1023, 767)]:
    let corner = TouchContact(id: 7, x: x.int32, y: y.int32, active: true)
    doAssert stylus.nativeDsPointer(@[corner], 1024, 768) ==
      dsPointer(SeparateDs, 1, 1024, 768, x, y, true)
