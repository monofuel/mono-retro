when defined(arm64) and cpuEndian == littleEndian:
  import
    nimsimd/neon

const
  PixelBytes = 4

when defined(arm64) and cpuEndian == littleEndian:
  const
    VectorPixels = 4
    RgbOrder = [2'u8, 1, 0, 3, 6, 5, 4, 7, 10, 9, 8, 11, 14, 13, 12, 15]
    OpaqueAlpha = [0'u8, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]

proc convertXrgbRow*(source, destination: pointer, count: int) {.inline.} =
  ## Convert native XRGB8888 pixels to opaque RGBA, allowing unaligned rows.
  let
    input = cast[ptr UncheckedArray[uint8]](source)
    output = cast[ptr UncheckedArray[uint8]](destination)
  var x = 0
  when defined(arm64) and cpuEndian == littleEndian:
    let
      order = vld1q_u8(unsafeAddr RgbOrder[0])
      alpha = vld1q_u8(unsafeAddr OpaqueAlpha[0])
    while x + VectorPixels <= count:
      let pixels = vqtbl1q_u8(vld1q_u8(addr input[x * PixelBytes]), order)
      vst1q_u8(addr output[x * PixelBytes], vorrq_u8(pixels, alpha))
      x += VectorPixels
  while x < count:
    var value: uint32
    copyMem(addr value, addr input[x * PixelBytes], PixelBytes)
    output[x * PixelBytes] = uint8((value shr 16) and 255)
    output[x * PixelBytes + 1] = uint8((value shr 8) and 255)
    output[x * PixelBytes + 2] = uint8(value and 255)
    output[x * PixelBytes + 3] = 255
    inc x
