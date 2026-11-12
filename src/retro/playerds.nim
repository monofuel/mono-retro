import
  pixie,
  ./[libretro, playergeometry, playervideo, touch]

export playergeometry

type
  DsLayout* = enum
    NoDsLayout, CombinedDs, SeparateDs
  DsStylus* = object
    active*: bool
    contactId: int32
  DualScreen* = object
    layout*: DsLayout
    panelWidth*, panelHeight*, desktopScale*: int
    options*: seq[CoreOption]
    topTitle*, bottomTitle*: string
    geometry*: DualGeometry
  CompanionGesture* = object
    blocked: bool

const
  DsWidth* = 256
  DsHeight* = 192
  EarthboundWidth* = EarthboundCompanionWidth
  EarthboundHeight* = EarthboundCompanionHeight
  ShowDsTouchCursor* = false
  PointerMaximum = 32767
  # Software is the pinned core's default; software-only builds omit its renderer option.
  DsOptions* = @[
    ("melonds_screen_layout1", "top-bottom"),
    ("melonds_screen_gap", "0"),
    ("melonds_number_of_screen_layouts", "1"),
    ("melonds_touch_mode", "touch"),
    ("melonds_show_cursor", if ShowDsTouchCursor: "always" else: "disabled")
  ]

proc earthboundDsOptions*(width, height: int): seq[CoreOption] =
  ## Enable the companion and pass decimal outdoor viewport dimensions.
  result = @[("decompbound_dual_screen", "enabled")]
  if width != EarthboundWidth or height != EarthboundHeight:
    result.add(("decompbound_viewport_width", $width))
    result.add(("decompbound_viewport_height", $height))

const
  EarthboundDsOptions* = earthboundDsOptions(EarthboundWidth, EarthboundHeight)

proc parseDsLayout*(value: string): DsLayout =
  ## Select an explicit DS presentation mode.
  case value
  of "combined": CombinedDs
  of "separate": SeparateDs
  else: raise newException(ValueError, "DS layout must be combined or separate")

proc selectDualScreen*(layout: DsLayout, earthbound = false, viewportWidth = EarthboundWidth,
    viewportHeight = EarthboundHeight): DualScreen =
  ## Build the exclusive melonDS or EarthBound dual-screen presentation.
  if earthbound and layout != NoDsLayout:
    raise newException(ValueError, "--earthbound-ds cannot be combined with --ds-layout")
  if earthbound:
    result = DualScreen(layout: SeparateDs, panelWidth: EarthboundWidth,
      panelHeight: EarthboundHeight, desktopScale: EarthboundDesktopScale,
      options: earthboundDsOptions(viewportWidth, viewportHeight), topTitle: "Game", bottomTitle: "Party",
      geometry: earthboundGeometry(viewportWidth, viewportHeight))
  elif layout == NoDsLayout:
    result = DualScreen(layout: NoDsLayout, desktopScale: 1)
  else:
    result = DualScreen(layout: layout, panelWidth: DsWidth, panelHeight: DsHeight,
      desktopScale: 1, options: DsOptions, topTitle: "Top", bottomTitle: "Touch",
      geometry: stackedGeometry(DsWidth, DsHeight))

proc validateDsDisplay*(layout: DsLayout, backend: string, outputs: int) =
  ## Require two DRM outputs for native DS presentation.
  if layout == NoDsLayout or backend == "x11": return
  if backend != "drm" or layout != SeparateDs or outputs != 2:
    raise newException(ValueError, "Native DS mode requires separate layout and two DRM outputs")

proc validateDsFrame*(width, height: int; panelWidth = DsWidth, panelHeight = DsHeight) =
  ## Require a stacked top/bottom software frame for the active dual-screen preset.
  if width != panelWidth or height != panelHeight * 2:
    raise newException(ValueError, "DS mode requires a " & $panelWidth & "x" &
      $(panelHeight * 2) & " top/bottom software frame")

proc dsScreen*(source, previous: Image, index: int; panelWidth = DsWidth,
    panelHeight = DsHeight): Image =
  ## Copy one dual-screen panel into reusable storage without retaining core memory.
  validateDsFrame(source.width, source.height, panelWidth, panelHeight)
  if index notin 0 .. 1: raise newException(ValueError, "Invalid DS screen")
  result = previous
  if result == nil or result.width != panelWidth or result.height != panelHeight:
    result = newImage(panelWidth, panelHeight)
  copyMem(addr result.data[0], unsafeAddr source.data[index * panelWidth * panelHeight],
    panelWidth * panelHeight * sizeof(ColorRGBX))

proc sameDsScreen*(source, previous: Image, index: int; panelWidth = DsWidth,
    panelHeight = DsHeight): bool =
  ## Compare a panel with its retained pixels before updating persistent scanout.
  validateDsFrame(source.width, source.height, panelWidth, panelHeight)
  if index notin 0 .. 1: raise newException(ValueError, "Invalid DS screen")
  if previous == nil or previous.width != panelWidth or previous.height != panelHeight:
    return false
  equalMem(unsafeAddr previous.data[0],
    unsafeAddr source.data[index * panelWidth * panelHeight],
    panelWidth * panelHeight * sizeof(ColorRGBX))

proc dsPointer*(layout: DsLayout, index, width, height, x, y: int,
    pressed: bool; panelWidth = DsWidth, panelHeight = DsHeight): PointerInput =
  ## Map a visible lower-screen point back into the core's combined viewport.
  if layout == NoDsLayout or (layout == SeparateDs and index != 1): return
  let
    sourceHeight = if layout == SeparateDs: panelHeight else: panelHeight * 2
    viewport = frameViewport(panelWidth, sourceHeight, width, height)
    localX = x - viewport.left
    localY = y - viewport.top
  if x < 0 or y < 0 or x >= width or y >= height or
      localX < 0 or localY < 0 or localX >= panelWidth * viewport.scale or
      localY >= sourceHeight * viewport.scale: return
  let
    sourceX = localX div viewport.scale
    sourceY = localY div viewport.scale + (if layout == SeparateDs: panelHeight else: 0)
  if sourceY < panelHeight: return
  # Pixel centers map back to the same emulated pixel through melonDS's matrix.
  result.x = int16(((sourceX * 2 + 1) * PointerMaximum div panelWidth) - PointerMaximum)
  result.y = int16(((sourceY * 2 + 1) * PointerMaximum div (panelHeight * 2)) - PointerMaximum)
  result.pressed = pressed

proc nativeDsPointer*(stylus: var DsStylus, contacts: seq[TouchContact],
    width, height: int; panelWidth = DsWidth, panelHeight = DsHeight): PointerInput =
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
        return dsPointer(SeparateDs, 1, width, height, contact.x.int, contact.y.int, true,
          panelWidth, panelHeight)
  stylus.active = false

proc dsScreen*(source, previous: Image, index: int, geometry: DualGeometry): Image =
  ## Copy an explicit source crop into owned panel storage.
  validateDualGeometry(source.width, source.height, geometry)
  if index notin 0..1: raise newException(ValueError, "Invalid DS screen")
  let crop = geometry.dualCrops()[index]
  result = previous
  if result == nil or result.width != crop.width or result.height != crop.height:
    result = newImage(crop.width, crop.height)
  if crop.x == 0 and crop.width == source.width:
    copyMem(addr result.data[0], unsafeAddr source.data[crop.y * source.width],
      result.data.len * sizeof(ColorRGBX))
    return
  for row in 0..<crop.height:
    copyMem(addr result.data[row * crop.width],
      unsafeAddr source.data[(crop.y + row) * source.width + crop.x],
      crop.width * sizeof(ColorRGBX))

proc sameDsScreen*(source, previous: Image, index: int, geometry: DualGeometry): bool =
  ## Compare an explicit crop to the previous panel image.
  validateDualGeometry(source.width, source.height, geometry)
  if index notin 0..1: raise newException(ValueError, "Invalid DS screen")
  let crop = geometry.dualCrops()[index]
  if previous == nil or previous.width != crop.width or previous.height != crop.height:
    return false
  if crop.x == 0 and crop.width == source.width:
    return equalMem(unsafeAddr previous.data[0],
      unsafeAddr source.data[crop.y * source.width], previous.data.len * sizeof(ColorRGBX))
  for row in 0..<crop.height:
    if not equalMem(unsafeAddr previous.data[row * crop.width],
        unsafeAddr source.data[(crop.y + row) * source.width + crop.x],
        crop.width * sizeof(ColorRGBX)):
      return false
  true

proc dsPointer*(layout: DsLayout, index, width, height, x, y: int,
    pressed: bool, geometry: DualGeometry): PointerInput =
  ## Map a companion pixel to normalized coordinates of the complete core frame.
  if layout == NoDsLayout or (layout == SeparateDs and index != 1): return
  let
    crop = visibleCrop(layout == SeparateDs, index, geometry)
    viewport = frameViewport(crop.width, crop.height, width, height)
    localX = x - viewport.left
    localY = y - viewport.top
  if x < 0 or y < 0 or x >= width or y >= height or localX < 0 or localY < 0 or
      localX >= crop.width * viewport.scale or localY >= crop.height * viewport.scale: return
  let
    sourceX = crop.x + localX div viewport.scale
    sourceY = crop.y + localY div viewport.scale
  if not geometry.companion.contains(sourceX, sourceY): return
  result.x = int16(((sourceX * 2 + 1) * PointerMaximum div geometry.frameWidth) - PointerMaximum)
  result.y = int16(((sourceY * 2 + 1) * PointerMaximum div geometry.frameHeight) - PointerMaximum)
  result.pressed = pressed

proc nativeDsPointer*(stylus: var DsStylus, contacts: seq[TouchContact],
    width, height: int, geometry: DualGeometry): PointerInput =
  ## Map one persistent native touch contact to the companion crop.
  if not stylus.active:
    for contact in contacts:
      if contact.active:
        stylus.contactId = contact.id
        stylus.active = true
        break
  if stylus.active:
    for contact in contacts:
      if contact.active and contact.id == stylus.contactId:
        return dsPointer(SeparateDs, 1, width, height, contact.x.int, contact.y.int,
          true, geometry)
  stylus.active = false

proc companionPointer*(gesture: var CompanionGesture, pointer: PointerInput,
    contactHeld: bool): PointerInput =
  ## Prevent re-entry from a border from turning one physical contact into two presses.
  result = pointer
  if not contactHeld:
    gesture.blocked = false
  elif not pointer.pressed:
    gesture.blocked = true
  if gesture.blocked: result.pressed = false
