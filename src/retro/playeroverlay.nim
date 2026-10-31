## App-owned achievement navigation, notification timing and presentation buffers.

import
  std/math,
  pixie,
  ./[overlayui, playergeometry, playervideo, ra_types]

export overlayui.OverlayPanelWidth, overlayui.OverlayPanelHeight,
  overlayui.OverlayRows, overlayui.OverlayRect, overlayui.OverlayLayout

const
  NoticeDurationNs = 4_000_000_000'i64
  MaximumQueuedNotices = 16
  DetailScrollStep = 36
  ToastInset = 4

type
  OverlayInput* = enum
    OverlayToggle, OverlayBack, OverlayActivate, OverlayPrevious, OverlayNext,
    OverlayPagePrevious, OverlayPageNext
  OverlayAction* = enum
    OverlayNone, OverlayOpened, OverlayClosed, OverlayChanged
  OverlayDisplay* = enum
    OverlaySingle, OverlayCombined, OverlaySeparate
  OverlayCrop* = tuple[x, y, width, height: int]
  OverlayCrops* = array[2, OverlayCrop]
  OverlayComposition* = object
    sourceImage*: Image
    crops*: OverlayCrops
    revision*: uint64
    changed*, modal*: bool
    uiCrop*: OverlayCrop
    uiOutput*: int
  OverlayPoint* = object
    inside*: bool
    x*, y*: float32
  CompositionKey = object
    display: OverlayDisplay
    stacked: bool
    panelWidth, panelHeight, active, width, height: int
    geometry: DualGeometry
  OverlayState* = ref object
    ui: OverlayUi
    snapshot: RaSnapshot
    opened, details: bool
    selected, first, scroll, maxScroll: int
    uiRevision: uint64
    queued: seq[RaNotice]
    notice: RaNotice
    noticeActive: bool
    noticeDeadline, lastUpdate: int64
    clockStarted: bool
    noticeRevision, renderedNoticeRevision: uint64
    panel, noticeImage, composite, frozenGame: Image
    composed: bool
    lastKey: CompositionKey
    lastCoreSequence, lastUiRevision, presentationRevision: uint64
    lastSource: pointer
    lastHadUi: bool

proc newOverlayState*(): OverlayState =
  ## Create UI state without reading credentials or changing emulation.
  OverlayState(ui: newOverlayUi(), snapshot: RaSnapshot(status: RaDisabled))

proc isOpen*(state: OverlayState): bool =
  ## Report whether the parent must pause emulation and route input to the panel.
  state != nil and state.opened

proc selectedIndex*(state: OverlayState): int =
  ## Expose the selected achievement index, or minus one for an empty list.
  if state.snapshot.achievements.len == 0: -1 else: state.selected

proc showingDetails*(state: OverlayState): bool =
  ## Report the current list/detail view without exposing mutable internal fields.
  state.details

proc changed(state: OverlayState) =
  ## Invalidate app-owned UI images after a visible state change.
  inc state.uiRevision

proc reconcileSelection(state: OverlayState) =
  ## Keep selection and paging inside the current cached achievement list.
  state.selected = clamp(state.selected, 0, max(0, state.snapshot.achievements.high))
  state.first = state.selected div OverlayRows * OverlayRows
  if state.snapshot.achievements.len == 0:
    state.details = false
    state.scroll = 0

proc updateSnapshot*(state: OverlayState, snapshot: RaSnapshot) =
  ## Update cheap metadata while preserving cached rows omitted by the worker.
  let
    newGame = snapshot.gameTitle != state.snapshot.gameTitle
    clearList = newGame or snapshot.status in
      {RaDisabled, RaUnconfigured, RaUnavailable, RaFailed}
    metadataChanged = snapshot.status != state.snapshot.status or
      snapshot.username != state.snapshot.username or newGame or
      snapshot.message != state.snapshot.message or
      snapshot.unlocked != state.snapshot.unlocked or snapshot.total != state.snapshot.total
    listAvailable = snapshot.hasList and not state.snapshot.hasList
  var rowsChanged = false
  if snapshot.hasList:
    rowsChanged = state.snapshot.achievements != snapshot.achievements
    if rowsChanged:
      let selectedId = if state.selected in 0 ..< state.snapshot.achievements.len:
          state.snapshot.achievements[state.selected].id else: 0'u32
      state.snapshot.achievements = snapshot.achievements
      for index, item in state.snapshot.achievements:
        if item.id == selectedId:
          state.selected = index
          break
    state.snapshot.hasList = true
  elif clearList:
    rowsChanged = state.snapshot.achievements.len > 0
    state.snapshot.achievements.setLen(0)
    state.snapshot.hasList = false
  state.snapshot.status = snapshot.status
  state.snapshot.username = snapshot.username
  state.snapshot.gameTitle = snapshot.gameTitle
  state.snapshot.message = snapshot.message
  state.snapshot.unlocked = snapshot.unlocked
  state.snapshot.total = snapshot.total
  if newGame:
    state.selected = 0
    state.details = false
    state.scroll = 0
  state.reconcileSelection()
  if metadataChanged or rowsChanged or listAvailable:
    state.changed()

proc setSnapshot*(state: OverlayState, snapshot: RaSnapshot) =
  ## Provide an equivalent snapshot setter for callers that retain this naming.
  state.updateSnapshot(snapshot)

proc enqueueNotices*(state: OverlayState, notices: openArray[RaNotice]) =
  ## Queue bounded text notifications without changing game or modal input state.
  for notice in notices:
    if state.queued.len >= MaximumQueuedNotices:
      state.queued.delete(0)
    state.queued.add(notice)

proc updateOverlay*(state: OverlayState, nowNs: int64) =
  ## Advance toast timing while preserving its remaining duration during a modal.
  let elapsed = if state.clockStarted: max(0'i64, nowNs - state.lastUpdate) else: 0'i64
  state.lastUpdate = nowNs
  state.clockStarted = true
  if state.opened:
    if state.noticeActive: state.noticeDeadline += elapsed
    return
  if state.noticeActive and nowNs >= state.noticeDeadline:
    state.noticeActive = false
    state.changed()
  if not state.noticeActive and state.queued.len > 0:
    state.notice = state.queued[0]
    state.queued.delete(0)
    state.noticeActive = true
    state.noticeDeadline = nowNs + NoticeDurationNs
    inc state.noticeRevision
    state.changed()

proc handleOverlay*(state: OverlayState, input: OverlayInput): OverlayAction =
  ## Apply UI commands after the parent has consumed their physical input edges.
  if input == OverlayToggle:
    state.opened = not state.opened
    if state.opened:
      state.frozenGame = nil
      state.details = false
      state.scroll = 0
    state.changed()
    return if state.opened: OverlayOpened else: OverlayClosed
  if not state.opened:
    return OverlayNone
  case input
  of OverlayBack:
    if state.details:
      state.details = false
      state.scroll = 0
    else:
      state.opened = false
      state.changed()
      return OverlayClosed
  of OverlayActivate:
    if state.snapshot.achievements.len == 0:
      return OverlayNone
    state.details = not state.details
    state.scroll = 0
    state.maxScroll = 0
  of OverlayPrevious, OverlayNext, OverlayPagePrevious, OverlayPageNext:
    let
      direction = if input in {OverlayPrevious, OverlayPagePrevious}: -1 else: 1
      page = input in {OverlayPagePrevious, OverlayPageNext}
    if state.details:
      let amount = if page: DetailScrollStep * OverlayRows else: DetailScrollStep
      state.scroll = clamp(state.scroll + direction * amount, 0, state.maxScroll)
    else:
      let amount = if page: OverlayRows else: 1
      state.selected += direction * amount
      state.reconcileSelection()
  of OverlayToggle:
    discard
  state.changed()
  result = OverlayChanged

proc controls*(state: OverlayState): OverlayLayout =
  ## Return exactly the panel-local hit rectangles used by the renderer.
  overlayLayout(state.first, state.snapshot.achievements.len, state.details)

proc pointerOverlay*(state: OverlayState, x, y: float32): OverlayAction =
  ## Activate a pointer release already mapped into the logical UI panel.
  if not state.opened:
    return OverlayNone
  let hit = state.controls().hitTest(x, y)
  case hit.control
  of OcResume: state.handleOverlay(OverlayToggle)
  of OcPrevious: state.handleOverlay(OverlayPagePrevious)
  of OcNext: state.handleOverlay(OverlayPageNext)
  of OcActivate: state.handleOverlay(OverlayActivate)
  of OcRow:
    state.selected = hit.index
    state.details = true
    state.scroll = 0
    state.maxScroll = 0
    state.changed()
    OverlayChanged
  of OcNone: OverlayNone

proc storage(previous: Image, width, height: int): Image =
  ## Reuse an owned image of the requested size without retaining core storage.
  if previous != nil and previous.width == width and previous.height == height:
    previous
  else:
    newImage(width, height)

proc copyRegion(source, target: Image, crop: OverlayCrop, x, y: int) =
  ## Copy complete source rows into disjoint application-owned presentation storage.
  for row in 0 ..< crop.height:
    copyMem(addr target.data[(y + row) * target.width + x],
      unsafeAddr source.data[(crop.y + row) * source.width + crop.x],
      crop.width * sizeof(ColorRGBX))

proc normalCrops(image: Image, display: OverlayDisplay, stacked: bool,
    panelWidth, panelHeight, active: int, geometry: DualGeometry): OverlayCrops =
  ## Preserve the normal combined/separate/active-screen presentation contract.
  if image == nil: return
  if display == OverlaySeparate and stacked:
    let actual = if geometry.frameWidth > 0: geometry else: stackedGeometry(panelWidth, panelHeight)
    validateDualGeometry(image.width, image.height, actual)
    result = actual.dualCrops()
  else:
    let output = if display == OverlaySeparate: active else: 0
    result[output] = (0, 0, image.width, image.height)

proc composeOverlay*(state: OverlayState, coreImage: Image, coreSequence: uint64,
    display: OverlayDisplay, stacked = false, panelWidth = 0, panelHeight = 0,
    active = 0, changed = true, geometry = DualGeometry()): OverlayComposition =
  ## Borrow normal frames directly and compose UI only into owned reusable images.
  if active notin 0 .. 1:
    raise newException(ValueError, "Invalid active overlay output")
  let
    width = if coreImage == nil: 0 else: coreImage.width
    height = if coreImage == nil: 0 else: coreImage.height
    key = CompositionKey(display: display, stacked: stacked,
      panelWidth: panelWidth, panelHeight: panelHeight, active: active,
      width: width, height: height, geometry: geometry)
    source = cast[pointer](coreImage)
    coreChanged = not state.composed or
      ((source != state.lastSource or coreSequence != state.lastCoreSequence) and changed)
    keyChanged = not state.composed or key != state.lastKey
    visibleUi = state.opened or state.noticeActive
    uiChanged = state.uiRevision != state.lastUiRevision and (visibleUi or state.lastHadUi)
    redraw = coreChanged or keyChanged or uiChanged
  result.modal = state.opened
  result.uiOutput = -1
  if redraw:
    inc state.presentationRevision
  result.revision = state.presentationRevision
  result.changed = redraw
  if state.opened:
    if state.frozenGame == nil and coreImage != nil:
      let gameHeight = if stacked and geometry.frameHeight > 0: geometry.game.height
        elif stacked: panelHeight else: height
      if gameHeight <= 0 or gameHeight > height or (stacked and geometry.frameWidth == 0 and panelWidth != width):
        raise newException(ValueError, "Invalid modal game crop")
      state.frozenGame = newImage(width, gameHeight)
      copyRegion(coreImage, state.frozenGame, (0, 0, width, gameHeight), 0, 0)
    if redraw or state.panel == nil:
      let rendered = state.ui.renderPanel(state.snapshot, state.selected, state.first,
        state.details, state.scroll, state.panel)
      state.panel = rendered.image
      state.maxScroll = rendered.maxScroll
      state.scroll = clamp(state.scroll, 0, state.maxScroll)
    if display == OverlaySingle:
      result.sourceImage = state.panel
      result.crops[0] = (0, 0, OverlayPanelWidth, OverlayPanelHeight)
      result.uiCrop = result.crops[0]
      result.uiOutput = 0
    else:
      let
        gameWidth = if state.frozenGame == nil: 0 else: state.frozenGame.width
        gameHeight = if state.frozenGame == nil: 0 else: state.frozenGame.height
        atlasWidth = max(gameWidth, OverlayPanelWidth)
        gameX = (atlasWidth - gameWidth) div 2
        uiX = (atlasWidth - OverlayPanelWidth) div 2
      if redraw or state.composite == nil:
        state.composite = storage(state.composite, atlasWidth, gameHeight + OverlayPanelHeight)
        state.composite.fill(rgbx(0, 0, 0, 255))
        if state.frozenGame != nil:
          copyRegion(state.frozenGame, state.composite,
            (0, 0, gameWidth, gameHeight), gameX, 0)
        copyRegion(state.panel, state.composite,
          (0, 0, OverlayPanelWidth, OverlayPanelHeight), uiX, gameHeight)
      result.sourceImage = state.composite
      result.uiCrop = (uiX, gameHeight, OverlayPanelWidth, OverlayPanelHeight)
      if display == OverlaySeparate:
        result.crops[0] = (gameX, 0, gameWidth, gameHeight)
        result.crops[1] = result.uiCrop
        result.uiOutput = 1
      else:
        result.crops[0] = (0, 0, atlasWidth, gameHeight + OverlayPanelHeight)
        result.uiOutput = 0
  else:
    result.crops = normalCrops(coreImage, display, stacked, panelWidth, panelHeight, active, geometry)
    result.sourceImage = coreImage
    if state.noticeActive and coreImage != nil:
      if redraw:
        state.composite = storage(state.composite, width, height)
        copyRegion(coreImage, state.composite, (0, 0, width, height), 0, 0)
        let toastWidth = max(1, width - ToastInset * 2)
        if state.noticeImage == nil or state.noticeImage.width != toastWidth or
            state.renderedNoticeRevision != state.noticeRevision:
          state.noticeImage = state.ui.renderNotice(state.notice, toastWidth, state.noticeImage)
          state.renderedNoticeRevision = state.noticeRevision
        state.composite.draw(state.noticeImage, translate(vec2(ToastInset.float32, ToastInset.float32)))
      result.sourceImage = state.composite
  state.composed = true
  state.lastKey = key
  state.lastSource = source
  state.lastCoreSequence = coreSequence
  state.lastUiRevision = state.uiRevision
  state.lastHadUi = visibleUi

proc compositionScreen*(composition: OverlayComposition, index: int,
    previous: Image = nil): Image =
  ## Borrow full frames, or copy a subregion into optional owned CPU storage.
  if index notin 0 .. 1:
    raise newException(ValueError, "Invalid overlay output")
  let crop = composition.crops[index]
  if composition.sourceImage == nil or crop.width == 0 or crop.height == 0:
    return nil
  if crop.x < 0 or crop.y < 0 or crop.width < 0 or crop.height < 0 or
      crop.x > composition.sourceImage.width or crop.y > composition.sourceImage.height or
      crop.width > composition.sourceImage.width - crop.x or
      crop.height > composition.sourceImage.height - crop.y:
    raise newException(ValueError, "Invalid overlay composition crop")
  if previous == nil and crop.x == 0 and crop.y == 0 and
      crop.width == composition.sourceImage.width and crop.height == composition.sourceImage.height:
    return composition.sourceImage
  result = storage(previous, crop.width, crop.height)
  copyRegion(composition.sourceImage, result, crop, 0, 0)

proc fitComposition*(composition: OverlayComposition, index, width, height: int,
    previous: Image = nil, forcedScale = 0): Image =
  ## Fit readable UI into small desktop windows while preserving integer game scaling.
  if width <= 0 or height <= 0:
    raise newException(ValueError, "Overlay output dimensions must be positive")
  let image = composition.compositionScreen(index)
  if forcedScale > 0 and image != nil:
    discard frameViewport(image.width, image.height, width, height, forcedScale)
  if not composition.modal or image == nil or (image.width <= width and image.height <= height):
    return fitFrame(image, previous, width, height, forcedScale)
  let
    scale = min(width.float64 / image.width.float64, height.float64 / image.height.float64)
    scaled = image.resize(max(1, int(image.width.float64 * scale)),
      max(1, int(image.height.float64 * scale)))
  result = fitFrame(scaled, previous, width, height)

proc overlayPointer*(composition: OverlayComposition, index, width, height: int,
    x, y: float32): OverlayPoint =
  ## Map physical pointer coordinates through the same crop and fit as presentation.
  if not composition.modal or index != composition.uiOutput or index notin 0 .. 1 or
      width <= 0 or height <= 0:
    return
  let crop = composition.crops[index]
  if crop.width <= 0 or crop.height <= 0: return
  let
    fit = min(width.float64 / crop.width.float64, height.float64 / crop.height.float64)
    scale = if fit >= 1: floor(fit) else: fit
    drawnWidth = max(1, int(crop.width.float64 * scale))
    drawnHeight = max(1, int(crop.height.float64 * scale))
    left = (width - drawnWidth) div 2
    top = (height - drawnHeight) div 2
    sourceX = crop.x.float32 + (x - left.float32) * crop.width.float32 / drawnWidth.float32
    sourceY = crop.y.float32 + (y - top.float32) * crop.height.float32 / drawnHeight.float32
  result.x = sourceX - composition.uiCrop.x.float32
  result.y = sourceY - composition.uiCrop.y.float32
  result.inside = x >= 0 and y >= 0 and x < width.float32 and y < height.float32 and
    result.x >= 0 and result.y >= 0 and result.x < composition.uiCrop.width.float32 and
    result.y < composition.uiCrop.height.float32
