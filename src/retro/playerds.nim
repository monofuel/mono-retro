import
  pixie,
  ./[libretro, playervideo, touch]

type
  DsLayout* = enum
    NoDsLayout, CombinedDs, SeparateDs
  DsStylus* = object
    active: bool
    contactId: int32

const
  DsWidth* = 256
  DsHeight* = 192
  PointerMaximum = 32767
  # Software is the pinned core's default; software-only builds omit its renderer option.
  DsOptions* = @[
    ("melonds_screen_layout1", "top-bottom"),
    ("melonds_screen_gap", "0"),
    ("melonds_number_of_screen_layouts", "1"),
    ("melonds_touch_mode", "touch"),
    ("melonds_mic_input", "silence")
  ]

proc parseDsLayout*(value: string): DsLayout =
  ## Select an explicit DS presentation mode.
  case value
  of "combined": CombinedDs
  of "separate": SeparateDs
  else: raise newException(ValueError, "DS layout must be combined or separate")

proc validateDsDisplay*(layout: DsLayout, backend: string, outputs: int) =
  ## Require two DRM outputs for native DS presentation.
  if layout == NoDsLayout or backend == "x11": return
  if backend != "drm" or layout != SeparateDs or outputs != 2:
    raise newException(ValueError, "Native DS mode requires separate layout and two DRM outputs")

proc validateDsFrame*(width, height: int) =
  ## Require the native zero-gap layout configured by the DS preset.
  if width != DsWidth or height != DsHeight * 2:
    raise newException(ValueError, "DS mode requires a 256x384 top/bottom software frame")

proc dsScreen*(source, previous: Image, index: int): Image =
  ## Copy one DS screen into reusable storage without retaining core memory.
  validateDsFrame(source.width, source.height)
  if index notin 0 .. 1: raise newException(ValueError, "Invalid DS screen")
  result = previous
  if result == nil or result.width != DsWidth or result.height != DsHeight:
    result = newImage(DsWidth, DsHeight)
  copyMem(addr result.data[0], unsafeAddr source.data[index * DsWidth * DsHeight],
    DsWidth * DsHeight * sizeof(ColorRGBX))

proc dsPointer*(layout: DsLayout, index, width, height, x, y: int,
    pressed: bool): PointerInput =
  ## Map a visible lower-screen point back into the core's combined viewport.
  if layout == NoDsLayout or (layout == SeparateDs and index != 1): return
  let
    sourceHeight = if layout == SeparateDs: DsHeight else: DsHeight * 2
    viewport = frameViewport(DsWidth, sourceHeight, width, height)
    localX = x - viewport.left
    localY = y - viewport.top
  if x < 0 or y < 0 or x >= width or y >= height or
      localX < 0 or localY < 0 or localX >= DsWidth * viewport.scale or
      localY >= sourceHeight * viewport.scale: return
  let
    sourceX = localX div viewport.scale
    sourceY = localY div viewport.scale + (if layout == SeparateDs: DsHeight else: 0)
  if sourceY < DsHeight: return
  # Pixel centers map back to the same emulated pixel through melonDS's matrix.
  result.x = int16(((sourceX * 2 + 1) * PointerMaximum div DsWidth) - PointerMaximum)
  result.y = int16(((sourceY * 2 + 1) * PointerMaximum div (DsHeight * 2)) - PointerMaximum)
  result.pressed = pressed

proc nativeDsPointer*(stylus: var DsStylus, contacts: seq[TouchContact],
    width, height: int): PointerInput =
  ## Keep one finger as the stylus until its contact ends or is cancelled.
  if not stylus.active:
    for contact in contacts:
      if contact.active:
        stylus.contactId = contact.id
        stylus.active = true
        break
  if stylus.active:
    for contact in contacts:
      if contact.active and contact.id == stylus.contactId:
        return dsPointer(SeparateDs, 1, width, height, contact.x.int, contact.y.int, true)
  stylus.active = false
