import
  pixie

const
  PixelRgb1555* = 0
  PixelXrgb8888* = 1
  PixelRgb565* = 2
  MaxFrameDimension = 8192

proc copyFrame*(previous: Image, data: pointer, width, height, pitch: int,
    format: int): Image =
  ## Copy a software frame while its core-owned storage is valid.
  if data == nil: return previous
  if data == cast[pointer](high(uint)):
    raise newException(ValueError, "Hardware-rendered frames are not supported")
  if width <= 0 or height <= 0 or width > MaxFrameDimension or height > MaxFrameDimension:
    raise newException(ValueError, "Invalid core frame dimensions")
  let bytes = if format == PixelXrgb8888: 4 else: 2
  if format notin [PixelRgb1555, PixelXrgb8888, PixelRgb565] or pitch < width * bytes:
    raise newException(ValueError, "Invalid core pixel format or row pitch")
  result = previous
  if result == nil or result.width != width or result.height != height:
    result = newImage(width, height)
  let source = cast[ptr UncheckedArray[byte]](data)
  for y in 0 ..< height:
    for x in 0 ..< width:
      var value: uint32
      copyMem(addr value, addr source[y * pitch + x * bytes], bytes)
      var r, g, b: uint8
      if format == PixelXrgb8888:
        r = uint8((value shr 16) and 255)
        g = uint8((value shr 8) and 255)
        b = uint8(value and 255)
      else:
        let
          greenBits = if format == PixelRgb565: 6 else: 5
          red = (value shr (5 + greenBits)) and 31
          green = (value shr 5) and uint32((1 shl greenBits) - 1)
          blue = value and 31
        r = uint8((red shl 3) or (red shr 2))
        g = if greenBits == 6: uint8((green shl 2) or (green shr 4))
          else: uint8((green shl 3) or (green shr 2))
        b = uint8((blue shl 3) or (blue shr 2))
      result.data[y * width + x] = rgbx(r, g, b, 255)

proc fitFrame*(source, previous: Image, width, height: int): Image =
  ## Center whole-number pixel scaling, clipping at native size if necessary.
  if width <= 0 or height <= 0:
    raise newException(ValueError, "Invalid presentation dimensions")
  result = previous
  if result == nil or result.width != width or result.height != height:
    result = newImage(width, height)
  result.fill(rgbx(0, 0, 0, 255))
  if source == nil: return
  let
    sourcePixels = cast[ptr UncheckedArray[ColorRGBX]](unsafeAddr source.data[0])
    targetPixels = cast[ptr UncheckedArray[ColorRGBX]](addr result.data[0])
    scale = max(1, min(width div source.width, height div source.height))
    viewWidth = source.width * scale
    viewHeight = source.height * scale
    left = (width - viewWidth) div 2
    top = (height - viewHeight) div 2
  for sourceY in 0 ..< source.height:
    let targetY = top + sourceY * scale
    if targetY < 0 or targetY >= height: continue
    var targetX = left
    for sourceX in 0 ..< source.width:
      let pixel = sourcePixels[sourceY * source.width + sourceX]
      for x in max(0, targetX) ..< min(width, targetX + scale):
        targetPixels[targetY * width + x] = pixel
      targetX += scale
    for y in targetY + 1 ..< min(height, targetY + scale):
      copyMem(addr targetPixels[y * width], addr targetPixels[targetY * width],
        width * sizeof(ColorRGBX))
