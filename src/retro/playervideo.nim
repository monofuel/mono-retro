import
  pixie

type
  FrameViewport* = object
    left*, top*, scale*: int

const
  PixelRgb1555* = 0
  PixelXrgb8888* = 1
  PixelRgb565* = 2
  MaxFrameDimension = 8192

proc frameViewport*(sourceWidth, sourceHeight, width, height: int): FrameViewport =
  ## Share integer scaling and crop offsets between rendering and pointer input.
  if min(sourceWidth, sourceHeight) <= 0 or min(width, height) <= 0:
    raise newException(ValueError, "Invalid viewport dimensions")
  result.scale = max(1, min(width div sourceWidth, height div sourceHeight))
  result.left = (width - sourceWidth * result.scale) div 2
  result.top = (height - sourceHeight * result.scale) div 2

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
  if format == PixelXrgb8888:
    for y in 0 ..< height:
      for x in 0 ..< width:
        var value: uint32
        copyMem(addr value, addr source[y * pitch + x * 4], 4)
        result.data[y * width + x] = rgbx(uint8((value shr 16) and 255),
          uint8((value shr 8) and 255), uint8(value and 255), 255)
    return
  let greenBits = if format == PixelRgb565: 6 else: 5
  for y in 0 ..< height:
    for x in 0 ..< width:
      var value: uint32
      copyMem(addr value, addr source[y * pitch + x * 2], 2)
      let
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
    viewport = frameViewport(source.width, source.height, width, height)
    scale = viewport.scale
    viewWidth = source.width * scale
    left = viewport.left
    top = viewport.top
    startX = max(0, -left)
    endX = min(source.width, width - left)
    rowWidth = min(width, viewWidth)
  # The clipped rows and integer scale bound every offset to the image storage.
  {.push overflowChecks: off.}
  for sourceY in max(0, -top) ..< min(source.height, height - top):
    let targetY = top + sourceY * scale
    let
      sourceRow = cast[ptr UncheckedArray[ColorRGBX]](
        addr sourcePixels[sourceY * source.width])
      targetRow = cast[ptr UncheckedArray[ColorRGBX]](
        addr targetPixels[targetY * width + max(0, left)])
    if scale == 1:
      copyMem(targetRow, addr sourceRow[startX], rowWidth * sizeof(ColorRGBX))
    else:
      template expandRow(factor: int) =
        for sourceX in startX ..< endX:
          let pixel = sourceRow[sourceX]
          for repeat in 0 ..< factor:
            targetRow[sourceX * factor + repeat] = pixel
      case scale
      of 2: expandRow(2)
      of 3: expandRow(3)
      of 4: expandRow(4)
      else: expandRow(scale)
    for y in targetY + 1 ..< min(height, targetY + scale):
      copyMem(addr targetPixels[y * width + max(0, left)], targetRow,
        rowWidth * sizeof(ColorRGBX))
  {.pop.}
