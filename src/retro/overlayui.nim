## Achievement panel drawing and the shared rectangles used for pointer input.

import
  std/unicode,
  pixie,
  ./[pattern, ra_types]

const
  OverlayPanelWidth* = 512
  OverlayPanelHeight* = 384
  OverlayRows* = 4
  FontBytes = staticRead("../../assets/Roboto-Regular.ttf")
  Background = 0x111923'u32
  Panel = 0x202E3E'u32
  Selected = 0x285E9E'u32
  Text = 0xEAF0F7'u32
  Muted = 0x9EAFC2'u32
  Accent = 0x67C7AE'u32
  Margin = 16
  RowsTop = 96
  RowHeight = 50
  RowGap = 4
  FooterTop = 328
  ButtonHeight = 36
  ButtonGap = 8
  ButtonCount = 4

type
  OverlayRect* = object
    x*, y*, width*, height*: int
  OverlayControl* = enum
    OcNone, OcResume, OcPrevious, OcNext, OcActivate, OcRow
  OverlayHit* = object
    control*: OverlayControl
    index*: int
  OverlayLayout* = object
    rows*: seq[OverlayRect]
    body*, resume*, previous*, next*, activate*: OverlayRect
    first*: int
  OverlayUi* = ref object
    font: Font

proc newOverlayUi*(): OverlayUi =
  ## Parse the existing Apache-licensed Roboto font once for the overlay.
  OverlayUi(font: newFont(parseTtf(FontBytes)))

proc contains*(area: OverlayRect, x, y: float32): bool =
  ## Hit-test the same half-open rectangles used when drawing controls.
  x >= area.x.float32 and y >= area.y.float32 and
    x < (area.x + area.width).float32 and y < (area.y + area.height).float32

proc overlayLayout*(first, count: int, details: bool): OverlayLayout =
  ## Keep panel controls fixed while list rows refer to their original indices.
  result.first = first
  result.body = OverlayRect(x: Margin, y: RowsTop,
    width: OverlayPanelWidth - Margin * 2, height: FooterTop - RowsTop - 16)
  if not details:
    for row in 0 ..< min(OverlayRows, max(0, count - first)):
      result.rows.add(OverlayRect(x: Margin, y: RowsTop + row * (RowHeight + RowGap),
        width: OverlayPanelWidth - Margin * 2, height: RowHeight))
  let width = (OverlayPanelWidth - Margin * 2 - ButtonGap * (ButtonCount - 1)) div ButtonCount
  result.resume = OverlayRect(x: Margin, y: FooterTop, width: width, height: ButtonHeight)
  result.previous = OverlayRect(x: Margin + width + ButtonGap, y: FooterTop,
    width: width, height: ButtonHeight)
  result.next = OverlayRect(x: Margin + (width + ButtonGap) * 2, y: FooterTop,
    width: width, height: ButtonHeight)
  result.activate = OverlayRect(x: Margin + (width + ButtonGap) * 3, y: FooterTop,
    width: width, height: ButtonHeight)

proc hitTest*(areas: OverlayLayout, x, y: float32): OverlayHit =
  ## Resolve a panel-local pointer position without consulting device APIs.
  for pair in [(areas.resume, OcResume), (areas.previous, OcPrevious),
      (areas.next, OcNext), (areas.activate, OcActivate)]:
    if pair[0].contains(x, y):
      return OverlayHit(control: pair[1])
  for row, area in areas.rows:
    if area.contains(x, y):
      return OverlayHit(control: OcRow, index: areas.first + row)

proc paint(ui: OverlayUi, image: Image, text: string, x, y: int,
    size: float32, tint = Text, width = 0) =
  ## Draw bounded, antialiased text onto an opaque application-owned image.
  ui.font.size = size
  ui.font.paint.color = color(float32(tint shr 16 and 255) / 255,
    float32(tint shr 8 and 255) / 255, float32(tint and 255) / 255, 1)
  image.fillText(ui.font.typeset(text, bounds = vec2(width.float32, 0)),
    translate(vec2(x.float32, y.float32)))

proc oneLine(ui: OverlayUi, text: string, size: float32, width: int): string =
  ## Ellipsize by Unicode characters so long titles cannot cover other controls.
  ui.font.size = size
  if ui.font.typeset(text).layoutBounds().x <= width.float32:
    return text
  var characters = text.toRunes()
  while characters.len > 0:
    characters.setLen(characters.len - 1)
    result = $characters & "…"
    if ui.font.typeset(result).layoutBounds().x <= width.float32:
      return
  result = ""

proc statusText(snapshot: RaSnapshot): string =
  ## Show account and availability without exposing credentials or transport details.
  case snapshot.status
  of RaDisabled: "Achievements disabled"
  of RaUnconfigured: "Not signed in"
  of RaConnecting: "Connecting…"
  of RaReady:
    snapshot.username & "  ·  " & $snapshot.unlocked & " / " & $snapshot.total & " unlocked"
  of RaUnavailable: "No achievements available"
  of RaFailed: "Achievements unavailable"

proc drawButton(ui: OverlayUi, image: Image, area: OverlayRect, label: string) =
  ## Paint one pointer target using the shared layout.
  image.rect(area.x, area.y, area.width, area.height, Panel)
  ui.paint(image, label, area.x + 12, area.y + 9, 16)

proc renderPanel*(ui: OverlayUi, snapshot: RaSnapshot, selected, first: int,
    details: bool, scroll: int, previous: Image = nil): tuple[image: Image, maxScroll: int] =
  ## Render the achievement list or selected description at a readable logical size.
  result.image = previous
  if result.image == nil or result.image.width != OverlayPanelWidth or
      result.image.height != OverlayPanelHeight:
    result.image = newImage(OverlayPanelWidth, OverlayPanelHeight)
  let
    image = result.image
    areas = overlayLayout(first, snapshot.achievements.len, details)
    title = if snapshot.gameTitle.len > 0: snapshot.gameTitle else: "RetroAchievements"
  image.fill(Background)
  ui.paint(image, "Achievements", Margin, 12, 24)
  ui.paint(image, ui.oneLine(title, 17, OverlayPanelWidth - Margin * 2), Margin, 43, 17, Accent)
  ui.paint(image, ui.oneLine(snapshot.statusText(), 14, OverlayPanelWidth - Margin * 2),
    Margin, 69, 14, Muted)
  if details and selected in 0 ..< snapshot.achievements.len:
    let
      item = snapshot.achievements[selected]
      content = newImage(areas.body.width, areas.body.height)
      state = if item.unlocked: "Unlocked" else: "Locked"
      heading = item.title & "\n" & state & "  ·  " & $item.points & " points\n\n"
      description = heading & item.description &
        (if item.progress.len > 0: "\n\nProgress: " & item.progress else: "")
    content.fill(Panel)
    ui.font.size = 18
    let height = ui.font.typeset(description,
      bounds = vec2((areas.body.width - 24).float32, 0)).layoutBounds().y.int + 24
    result.maxScroll = max(0, height - areas.body.height)
    ui.paint(content, description, 12, 12 - clamp(scroll, 0, result.maxScroll), 18,
      width = areas.body.width - 24)
    image.draw(content, translate(vec2(areas.body.x.float32, areas.body.y.float32)))
  elif areas.rows.len > 0:
    for row, area in areas.rows:
      let
        index = first + row
        item = snapshot.achievements[index]
        state = if item.unlocked: "Unlocked" else: "Locked"
      image.rect(area.x, area.y, area.width, area.height,
        if index == selected: Selected else: Panel)
      ui.paint(image, ui.oneLine(item.title, 17, area.width - 24), area.x + 12,
        area.y + 6, 17, if item.unlocked: Accent else: Text)
      ui.paint(image, state & "  ·  " & $item.points & " points", area.x + 12, area.y + 29, 12, Muted)
  else:
    let message = if snapshot.message.len > 0: snapshot.message
      elif snapshot.status == RaReady and not snapshot.hasList: "Loading achievements…"
      else: snapshot.statusText()
    let content = newImage(areas.body.width, areas.body.height)
    content.fill(Background)
    ui.paint(content, message, 0, 10, 18, Muted, areas.body.width)
    image.draw(content, translate(vec2(areas.body.x.float32, areas.body.y.float32)))
  ui.drawButton(image, areas.resume, "Resume")
  ui.drawButton(image, areas.previous, if details: "Up" else: "Prev")
  ui.drawButton(image, areas.next, if details: "Down" else: "Next")
  ui.drawButton(image, areas.activate, if details: "List" else: "Details")
  ui.paint(image, "MENU / F1: Resume     A / Enter: " &
    (if details: "List" else: "Details") & "     B / Esc: Back",
    Margin, 370, 10, Muted)

proc renderNotice*(ui: OverlayUi, notice: RaNotice, width: int,
    previous: Image = nil): Image =
  ## Render a compact opaque toast in the game's native pixel coordinates.
  if width <= 0:
    raise newException(ValueError, "Achievement toast width must be positive")
  let
    factor = clamp(width.float32 / 256, 0.5'f32, 2'f32)
    height = max(24, int(62 * factor))
    margin = max(4, int(8 * factor))
  result = previous
  if result == nil or result.width != width or result.height != height:
    result = newImage(width, height)
  result.fill(Panel)
  ui.paint(result, "Achievement unlocked  ·  " & $notice.points & " points",
    margin, margin, 9 * factor, Accent)
  ui.paint(result, ui.oneLine(notice.title, 12 * factor, width - margin * 2),
    margin, int(23 * factor), 12 * factor)
  ui.paint(result, ui.oneLine(notice.description, 9 * factor, width - margin * 2),
    margin, int(43 * factor), 9 * factor, Muted)
