import
  pixie,
  ./[libretro, playervideo, touch]

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
  CompanionGesture* = object
    blocked: bool

const
  DsWidth* = 256
  DsHeight* = 192
  EarthboundWidth* = 256
  EarthboundHeight* = 224
  EarthboundDesktopScale* = 2
  ShowDsTouchCursor* = false
  PointerMaximum = 32767
  # Software is the pinned core's default; software-only builds omit its renderer option.
  DsOptions* = @[
    ("melonds_screen_layout1", "top-bottom"),
    ("melonds_screen_gap", "0"),
    ("melonds_number_of_screen_layouts", "1"),
    ("melonds_touch_mode", "touch"),
    ("melonds_show_cursor", if ShowDsTouchCursor: "always" else: "disabled"),
    ("melonds_mic_input", "silence")
  ]
  EarthboundDsOptions* = @[
    ("decompbound_dual_screen", "enabled")
  ]

proc parseDsLayout*(value: string): DsLayout =
  ## Select an explicit DS presentation mode.
  case value
  of "combined": CombinedDs
  of "separate": SeparateDs
  else: raise newException(ValueError, "DS layout must be combined or separate")

proc selectDualScreen*(layout: DsLayout, earthbound = false): DualScreen =
  ## Build the exclusive melonDS or EarthBound dual-screen presentation.
  if earthbound and layout != NoDsLayout:
    raise newException(ValueError, "--earthbound-ds cannot be combined with --ds-layout")
  if earthbound:
    result = DualScreen(layout: SeparateDs, panelWidth: EarthboundWidth,
      panelHeight: EarthboundHeight, desktopScale: EarthboundDesktopScale,
      options: EarthboundDsOptions, topTitle: "Game", bottomTitle: "Party")
  elif layout == NoDsLayout:
    result = DualScreen(layout: NoDsLayout, desktopScale: 1)
  else:
    result = DualScreen(layout: layout, panelWidth: DsWidth, panelHeight: DsHeight,
      desktopScale: 1, options: DsOptions, topTitle: "Top", bottomTitle: "Touch")

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

proc companionPointer*(gesture: var CompanionGesture, pointer: PointerInput,
    contactHeld: bool): PointerInput =
  ## Prevent re-entry from a border from turning one physical contact into two presses.
  result = pointer
  if not contactHeld:
    gesture.blocked = false
  elif not pointer.pressed:
    gesture.blocked = true
  if gesture.blocked: result.pressed = false
