import
  retro/playerpixels

for width in 0 .. 65:
  let pitch = width * 4 + 3
  var
    source = newSeq[uint8](pitch * 3 + 1)
    expected = newSeq[uint8](width * 4 * 3)
  for y in 0 .. 2:
    for x in 0 ..< width:
      let
        r = uint8((x * 17 + y * 3) mod 256)
        g = uint8((x * 41 + y * 7) mod 256)
        b = uint8((x * 73 + y * 11) mod 256)
        value = 0x7b000000'u32 or (r.uint32 shl 16) or (g.uint32 shl 8) or b.uint32
        offset = (y * width + x) * 4
      copyMem(addr source[1 + y * pitch + x * 4], unsafeAddr value, 4)
      expected[offset] = r
      expected[offset + 1] = g
      expected[offset + 2] = b
      expected[offset + 3] = 255
  for y in 0 .. 2:
    var output = newSeq[uint8](width * 4 + 2)
    output[0] = 0x55
    output[^1] = 0xaa
    convertXrgbRow(addr source[1 + y * pitch], addr output[1], width)
    doAssert output[0] == 0x55 and output[^1] == 0xaa
    for index in 0 ..< width * 4:
      doAssert output[index + 1] == expected[y * width * 4 + index]
