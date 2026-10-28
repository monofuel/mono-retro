import
  pixie,
  ./[menu, pattern, powercontrol, systeminfo]

type
  ScreenRole* = enum
    SingleScreen, TopScreen, BottomScreen
  UiRect* = object
    x*, y*, width*, height*: int
  MenuLayout* = object
    rows*: seq[UiRect]
    body*, action*, cancel*, confirm*: UiRect
  LauncherUi* = ref object
    font: Font

const
  FontBytes = staticRead("../../assets/Roboto-Regular.ttf")
  BackgroundColor = 0x111923'u32
  PanelColor = 0x202e3e'u32
  SelectedColor = 0x285e9e'u32
  TextColor = 0xeaf0f7'u32
  MutedColor = 0x9eafc2'u32
  AccentColor = 0x67c7ae'u32
  ErrorColor = 0xffa08e'u32
  WarningColor = 0xffcd7d'u32
  Margin = 28
  ToolbarHeight = 64
  RowHeight = 68
  ButtonHeight = 52
  RowGap = 8
  ErrorSpace = 48

proc newLauncherUi*(): LauncherUi =
  ## Parse the embedded, licensed font once for the lifetime of the UI.
  LauncherUi(font: newFont(parseTtf(FontBytes)))

proc contains*(area: UiRect, point: Vec2): bool =
  ## Hit-test using the same rectangles used to render controls.
  point.x >= area.x.float32 and point.y >= area.y.float32 and
    point.x < (area.x + area.width).float32 and
    point.y < (area.y + area.height).float32

proc layout*(width, height: int, role: ScreenRole, rows = MenuLabels.len): MenuLayout =
  ## Keep controls inside the drawable area on all three supported displays.
  let top = if role == BottomScreen: Margin else: ToolbarHeight + Margin
  result.action = UiRect(x: Margin, y: height - ButtonHeight - 32,
    width: max(1, width - Margin * 2), height: ButtonHeight)
  let
    firstRow = top + 42
    rowHeight = max(32, min(RowHeight,
      (result.action.y - firstRow - ErrorSpace - RowGap * (rows - 1)) div rows))
  result.rows.setLen(rows)
  for index in 0 ..< rows:
    result.rows[index] = UiRect(x: Margin, y: firstRow + index * (rowHeight + RowGap),
      width: max(1, width - Margin * 2), height: rowHeight)
  result.cancel = result.action
  result.cancel.width = max(1, (result.action.width - RowGap) div 2)
  result.confirm = UiRect(x: result.cancel.x + result.cancel.width + RowGap,
    y: result.cancel.y, width: result.cancel.width, height: result.cancel.height)
  result.body = UiRect(x: Margin, y: top + 44, width: max(1, width - Margin * 2),
    height: max(1, result.action.y - top - 60))

proc label(ui: LauncherUi, image: Image, text: string, x, y: int,
    size = 22'f32, tint = TextColor) =
  ## Draw normal antialiased type without using the tester's diagnostic glyphs.
  ui.font.size = size
  ui.font.paint.color = color(float32(tint shr 16 and 255) / 255,
    float32(tint shr 8 and 255) / 255, float32(tint and 255) / 255, 1)
  image.fillText(ui.font.typeset(text), translate(vec2(x.float32, y.float32)))

proc toolbar(ui: LauncherUi, image: Image, title: string, power: PowerStatus) =
  ## Keep connection state and battery flow visible as separate toolbar lines.
  image.rect(0, 0, image.width, ToolbarHeight, PanelColor)
  ui.label(image, title, Margin, 20, 22)
  let
    x = max(image.width div 2, image.width - 315)
    reading = power.selectedBattery()
    draining = power.external and power.batteryFlow() == DischargingFlow
    tint = if draining: WarningColor else: AccentColor
  image.rect(x, 25, 32, 18, MutedColor)
  image.rect(x + 32, 30, 3, 8, MutedColor)
  image.rect(x + 2, 27, 28, 14, BackgroundColor)
  if reading.percent >= 0:
    image.rect(x + 3, 28, 26 * reading.percent div 100, 12, tint)
  ui.label(image, power.batteryText(), x + 46, if power.external: 10 else: 23, 18)
  if power.external:
    ui.label(image, power.chargeText(), x + 46, 35, 16,
      if draining: WarningColor else: TextColor)

proc render*(ui: LauncherUi, state: MenuState, title: string, power: PowerStatus,
    lines: seq[string], width, height: int, role: ScreenRole): tuple[image: Image, maxScroll: int] =
  ## Render one screen; return the information pane's actual scroll bound.
  result.image = newCanvas(width, height)
  result.image.fill(BackgroundColor)
  let
    image = result.image
    labels = state.labels()
    areas = layout(width, height, role, labels.len)
    showInfo = state.info and role != TopScreen
    confirming = state.confirmation != NoAction
    showMenu = role != BottomScreen and not showInfo and (not confirming or role == TopScreen)
    top = if role == BottomScreen: Margin else: ToolbarHeight + Margin
  if role != BottomScreen: ui.toolbar(image, title, power)
  if showMenu:
    ui.label(image, "mono-retro", Margin, top, 28)
    for index, text in labels:
      let area = areas.rows[index]
      image.rect(area.x, area.y, area.width, area.height,
        if state.selected == index: SelectedColor else: PanelColor)
      ui.label(image, text, area.x + 20, area.y + (area.height - 28) div 2, 24)
    ui.label(image, "A / Enter: Open     B / Escape: Back", Margin, height - 25, 16, MutedColor)
  if confirming and role != TopScreen:
    let
      reboot = state.confirmation == RebootSystem
      heading = if reboot: "Reboot this device?" else: "Shut down this device?"
      blocked = power.powerBlockReason()
    ui.label(image, if state.busy:
      (if reboot: "Rebooting…" else: "Shutting down…") else: heading, Margin, top, 30)
    ui.label(image, if blocked.len > 0: blocked else:
      "Choose Cancel to return to the menu.", Margin, top + 65, 20, MutedColor)
    if not state.busy:
      let
        cancel = areas.cancel
        confirm = areas.confirm
      image.rect(cancel.x, cancel.y, cancel.width, cancel.height,
        if not state.confirmYes: SelectedColor else: PanelColor)
      image.rect(confirm.x, confirm.y, confirm.width, confirm.height,
        if state.confirmYes and blocked.len == 0: SelectedColor else: PanelColor)
      ui.label(image, "Cancel", cancel.x + 20, cancel.y + 15, 22)
      ui.label(image, if reboot: "Reboot" else: "Shut Down", confirm.x + 20, confirm.y + 15, 22)
  elif showInfo:
    ui.label(image, "System Info", Margin, top, 28)
    let content = newCanvas(areas.body.width, areas.body.height)
    content.fill(BackgroundColor)
    ui.font.size = 21
    ui.font.paint.color = color(0.92, 0.95, 0.98, 1)
    var offset = 0
    for line in lines:
      let
        arrangement = ui.font.typeset(line, bounds = vec2(areas.body.width.float32, 0))
        lineHeight = max(28, int(arrangement.layoutBounds().y) + 10)
        y = offset - state.scroll
      if y + lineHeight >= 0 and y < content.height:
        content.fillText(arrangement, translate(vec2(0, y.float32)))
      offset += lineHeight
    result.maxScroll = max(0, offset - content.height)
    image.draw(content, translate(vec2(areas.body.x.float32, areas.body.y.float32)))
  elif role == BottomScreen:
    ui.label(image, labels[state.selected], Margin, top, 30)
    let description = case state.entryIndex()
      of -1: "Play Lost in Blue with melonDS DS.\n\nTouch the lower screen. Hold Select + Start to return."
      of 0: "Play EarthBound with decompbound.\n\nL2 swaps screens. Hold Select + Start to return."
      of 1: "Check the screens, controls, touch and sound.\n\nHold Select + Start in the tester to return here."
      of 2: "Show the kernel, operating system, battery gauges\nand local network addresses."
      of 3: "Restart the device. You will be asked to confirm."
      else: "Power off the device. You will be asked to confirm."
    ui.label(image, description, Margin, top + 70, 24, MutedColor)
  if role != TopScreen and not confirming:
    let area = areas.action
    image.rect(area.x, area.y, area.width, area.height, SelectedColor)
    ui.label(image, if showInfo: "Back" else: "Open " & labels[state.selected],
      area.x + 20, area.y + 15, 22)
  if state.error.len > 0:
    ui.label(image, state.error, Margin, height - 112, 18, ErrorColor)
