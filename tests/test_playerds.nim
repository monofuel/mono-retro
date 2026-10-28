import
  pixie,
  retro/[libretro, playerds]

doAssert parseDsLayout("combined") == CombinedDs
doAssert parseDsLayout("separate") == SeparateDs
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
