import
  pixie,
  ./[menu, pattern, systeminfo]

type
  ScreenRole* = enum
    SingleScreen, TopScreen, BottomScreen
  UiRect* = object
    x*, y*, width*, height*: int
  MenuLayout* = object
    rows*: array[2, UiRect]
    body*, action*: UiRect
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
  Margin = 28
  ToolbarHeight = 64
  RowHeight = 68
  ButtonHeight = 52

proc newLauncherUi*(): LauncherUi =
  ## Parse the embedded, licensed font once for the lifetime of the UI.
  LauncherUi(font: newFont(parseTtf(FontBytes)))

proc contains*(area: UiRect, point: Vec2): bool =
  ## Hit-test using the same rectangles used to render controls.
  point.x >= area.x.float32 and point.y >= area.y.float32 and
    point.x < (area.x + area.width).float32 and
    point.y < (area.y + area.height).float32

proc layout*(width, height: int, role: ScreenRole): MenuLayout =
  ## Keep controls inside the drawable area on all three supported displays.
  let top = if role == BottomScreen: Margin else: ToolbarHeight + Margin
  for index in 0 .. 1:
    result.rows[index] = UiRect(x: Margin, y: top + 42 + index * (RowHeight + 12),
      width: max(1, width - Margin * 2), height: RowHeight)
  result.action = UiRect(x: Margin, y: height - ButtonHeight - 32,
    width: max(1, width - Margin * 2), height: ButtonHeight)
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
  ## Show kernel-reported power status on the primary screen.
  image.rect(0, 0, image.width, ToolbarHeight, PanelColor)
  ui.label(image, title, Margin, 20, 22)
  let
    x = max(image.width div 2, image.width - 315)
    reading = power.selectedBattery()
  image.rect(x, 25, 32, 18, MutedColor)
  image.rect(x + 32, 30, 3, 8, MutedColor)
  image.rect(x + 2, 27, 28, 14, BackgroundColor)
  if reading.percent >= 0:
    image.rect(x + 3, 28, 26 * reading.percent div 100, 12, AccentColor)
  ui.label(image, power.batteryText(), x + 46, 23, 18)

proc render*(ui: LauncherUi, state: MenuState, title: string, power: PowerStatus,
    lines: seq[string], width, height: int, role: ScreenRole): tuple[image: Image, maxScroll: int] =
  ## Render one screen; return the information pane's actual scroll bound.
  result.image = newCanvas(width, height)
  result.image.fill(BackgroundColor)
  let
    image = result.image
    areas = layout(width, height, role)
    showInfo = state.info and role != TopScreen
    showMenu = role != BottomScreen and not showInfo
    top = if role == BottomScreen: Margin else: ToolbarHeight + Margin
  if role != BottomScreen: ui.toolbar(image, title, power)
  if showMenu:
    ui.label(image, "mono-retro", Margin, top, 28)
    for index, text in MenuLabels:
      let area = areas.rows[index]
      image.rect(area.x, area.y, area.width, area.height,
        if state.selected == index: SelectedColor else: PanelColor)
      ui.label(image, text, area.x + 20, area.y + 21, 24)
    ui.label(image, "A / Enter: Open     B / Escape: Back", Margin, height - 25, 16, MutedColor)
  if showInfo:
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
    ui.label(image, MenuLabels[state.selected], Margin, top, 30)
    let description = if state.selected == 0:
      "Check the screens, controls, touch and sound.\n\nHold Select + Start in the tester to return here."
      else: "Show the kernel, operating system, battery gauges\nand local network addresses."
    ui.label(image, description, Margin, top + 70, 24, MutedColor)
  if role != TopScreen:
    let area = areas.action
    image.rect(area.x, area.y, area.width, area.height, SelectedColor)
    ui.label(image, if showInfo: "Back" else: "Open " & MenuLabels[state.selected],
      area.x + 20, area.y + 15, 22)
  if state.error.len > 0:
    ui.label(image, state.error, Margin, height - 112, 18, ErrorColor)
