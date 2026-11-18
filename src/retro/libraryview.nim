import
  std/[algorithm, os, strutils, tables, unicode, wordwrap],
  pixie,
  ./[gamelibrary, launcherui, menuthemes, pattern, systeminfo]

type
  LibraryPage* = enum
    GamesPage, ToolsPage, CollectionsPage, GamePage, SystemPage, PairPage,
    PowerPage, ConflictPage, WorkbenchPage, AppearancePage
  ViewAction* = enum
    NoViewAction, SelectGame, PlayGame, ShowGames, ShowTools, TestHardware,
    ShowSystem, ShowCollections, ConnectRomm, SyncRomm, DisconnectRomm,
    RebootDevice, ShutdownDevice, RescanGames, ShowAppearance, SelectTheme,
    ApplyTheme, CancelAppearance, PreviousFilter, NextFilter, ToggleCollection,
    CancelDialog, ConfirmPower, UseLocalSave, UseRemoteSave, SelectFilter
  ViewTarget* = object
    area*: UiRect
    action*: ViewAction
    index*: int
  LibraryViewState* = object
    page*, appearanceReturn*: LibraryPage
    theme*, previewTheme*: MenuTheme
    selected*, tool*, collection*, filter*, scroll*, workbench*: int
    message*: string
    busy*, error*, confirmYes*, reboot*: bool
    transition*: float32
  LibraryUi* = ref object
    text: LauncherUi
    covers: Table[string, Image]
    palette: ThemePalette
  LibraryLayout* = ThemeLayout
  PageLayout* = object
    targets*: seq[ViewTarget]
    columns*: int

const
  MaximumCovers = 24
  CoverWidth = 360
  CoverHeight = 480
  MaximumCoverPixels = 4_000_000
  WorkbenchFooterHeight = 64
  ToolActions* = [TestHardware, ShowSystem, ShowAppearance, ShowCollections,
    ConnectRomm, SyncRomm, DisconnectRomm, RebootDevice, ShutdownDevice, RescanGames]
  WorkbenchActions* = [TestHardware, ShowSystem, ShowGames, SyncRomm, ShowAppearance, ShowTools]
  ActionLabels*: array[ViewAction, string] = ["", "", "Play", "Games", "Menu",
    "Hardware Test", "System Info", "RomM collections", "Connect to RomM",
    "Sync now", "Disconnect RomM", "Reboot", "Shut down", "Rescan games",
    "Appearance", "", "Apply", "Cancel", "Previous filter", "Next filter", "",
    "Cancel", "Confirm", "Local save", "RomM save", ""]
  DefaultText = 0xffffffff'u32

proc newLibraryUi*(): LibraryUi =
  ## Reuse the launcher's embedded font and keep artwork memory bounded.
  LibraryUi(text: newLauncherUi(), palette: ThemePalettes[LibraryTheme])

proc clearCovers*(ui: LibraryUi) =
  ## Reload thumbnail bytes after a completed artwork update.
  ui.covers.clear()

proc shortText(text: string, length: int): string =
  ## Truncate labels at Unicode character boundaries.
  let characters = text.toRunes()
  if characters.len <= length: text else: $characters[0 ..< max(0, length - 1)] & "…"

proc label(ui: LibraryUi, image: Image, text: string, x, y: int,
    size = 22'f32, tint = DefaultText) =
  ## Use the current theme's foreground unless a semantic tint is explicit.
  ui.text.label(image, text, x, y, size, if tint == DefaultText: ui.palette.text else: tint)

proc filters*(index: LibraryIndex): seq[string] =
  ## Keep navigation filters stable across scans and metadata updates.
  result = @["All", "Recent", "Favourites"]
  for game in index.games:
    let label = game.platform.toUpperAscii()
    if label notin result: result.add label
  if result.len > 3: result[3 .. ^1] = result[3 .. ^1].sorted()

proc visibleGames*(index: LibraryIndex, filter: int): seq[LibraryGame] =
  ## Return shared game identities in the current view's presentation order.
  let choices = index.filters()
  let selected = choices[clamp(filter, 0, choices.high)]
  for game in index.games:
    if selected == "Favourites" and not game.favourite: continue
    if selected == "Recent" and game.lastPlayed == 0: continue
    if filter >= 3 and game.platform.toUpperAscii() != selected: continue
    result.add game
  if selected == "Recent":
    result.sort(proc(a, b: LibraryGame): int = cmp(b.lastPlayed, a.lastPlayed))

proc libraryLayout*(width, height, selected, count: int): LibraryLayout =
  ## Retain the original library grid for existing callers.
  themeLayout(LibraryTheme, width, height, selected, count)

proc homePage*(theme: MenuTheme): LibraryPage =
  ## Give the developer theme a tools-first home without replacing the library.
  if theme == WorkbenchTheme: WorkbenchPage else: GamesPage

proc target(area: UiRect, action: ViewAction, index = 0): ViewTarget =
  ## Associate one visible control with its application action.
  ViewTarget(area: area, action: action, index: index)

proc pageLayout*(state: LibraryViewState, index: LibraryIndex,
    width, height: int): PageLayout =
  ## Share every interactive rectangle between rendering and pointer handling.
  let games = index.visibleGames(state.filter)
  result.columns = 1
  case state.page
  of GamesPage:
    let layout = themeLayout(state.theme, width, height, state.selected, games.len)
    result.columns = layout.columns
    for position, area in layout.cards:
      result.targets.add target(area, SelectGame, layout.first + position)
    result.targets.add target(layout.play, PlayGame)
    result.targets.add target(layout.tools, ShowTools)
    if state.theme == PocketTheme:
      let
        choices = index.filters()
        visible = min(choices.len, max(1, width div 100))
        first = clamp(state.filter - visible div 2, 0, max(0, choices.len - visible))
        tabWidth = (width - 32) div visible
      for position in 0 ..< visible:
        result.targets.add target(UiRect(x: 16 + position * tabWidth, y: 72,
          width: tabWidth - 4, height: 28), SelectFilter, first + position)
    else:
      result.targets.add target(layout.previous, PreviousFilter)
      result.targets.add target(layout.next, NextFilter)
  of WorkbenchPage:
    result.columns = if width >= 300: 2 else: 1
    let
      rows = (WorkbenchActions.len + result.columns - 1) div result.columns
      gap = 10
      top = 108
      itemWidth = (width - 32 - gap * (result.columns - 1)) div result.columns
      itemHeight = max(16, min(74, (height - top - WorkbenchFooterHeight - gap * (rows - 1)) div rows))
    for position, action in WorkbenchActions:
      result.targets.add target(UiRect(x: 16 + position mod result.columns * (itemWidth + gap),
        y: top + position div result.columns * (itemHeight + gap),
        width: itemWidth, height: itemHeight), action, position)
  of ToolsPage, CollectionsPage:
    let
      count = if state.page == ToolsPage: ToolActions.len else: index.collections.len
      selection = if state.page == ToolsPage: state.tool else: state.collection
      rows = max(1, (height - 150) div 43)
      first = max(0, selection - rows + 1)
    for item in first ..< min(count, first + rows):
      result.targets.add target(UiRect(x: 16, y: 115 + (item - first) * 43,
        width: width - 32, height: 38),
        if state.page == ToolsPage: ToolActions[item] else: ToggleCollection, item)
  of AppearancePage:
    let footer = themeLayout(state.theme, width, height, 0, 0)
    result.targets.add target(footer.play, ApplyTheme)
    result.targets.add target(footer.tools, CancelAppearance)
    for theme in MenuTheme:
      let itemWidth = (width - 32) div ThemeNames.len
      result.targets.add target(UiRect(x: 16 + ord(theme) * itemWidth, y: 74,
        width: itemWidth - 4, height: 34), SelectTheme, ord(theme))
  of PowerPage, ConflictPage:
    let footer = themeLayout(state.theme, width, height, 0, 0)
    result.targets.add target(footer.play, if state.page == PowerPage: CancelDialog else: UseLocalSave)
    result.targets.add target(footer.tools, if state.page == PowerPage: ConfirmPower else: UseRemoteSave)
  of GamePage:
    let footer = themeLayout(state.theme, width, height, 0, 0)
    result.targets.add target(footer.play, PlayGame)
    result.targets.add target(footer.tools, ShowGames)
  else: discard

proc hitTarget*(layout: PageLayout, point: Vec2): ViewTarget =
  ## Ignore taps outside controls rather than activating an entire page.
  for item in layout.targets:
    if item.area.contains(point): return item

proc moveSelection*(state: var LibraryViewState, index: LibraryIndex,
    width, height, direction: int, vertical: bool) =
  ## Respect each theme's navigation geometry, including the horizontal showcase.
  let columns = state.pageLayout(index, width, height).columns
  case state.page
  of GamesPage:
    state.selected = clamp(state.selected + direction * (if vertical: columns else: 1),
      0, max(0, index.visibleGames(state.filter).high))
  of ToolsPage: state.tool = clamp(state.tool + direction, 0, ToolActions.high)
  of CollectionsPage: state.collection = clamp(state.collection + direction, 0, max(0, index.collections.high))
  of WorkbenchPage:
    state.workbench = clamp(state.workbench + direction * (if vertical: columns else: 1), 0, WorkbenchActions.high)
  of AppearancePage:
    state.previewTheme = MenuTheme((ord(state.previewTheme) + ThemeNames.len + direction) mod ThemeNames.len)
  of SystemPage: state.scroll = max(0, state.scroll + direction)
  of PowerPage, ConflictPage: state.confirmYes = direction > 0
  else: discard

proc selectedTarget*(state: LibraryViewState): ViewTarget =
  ## Translate controller confirmation into the same action as a visible button.
  case state.page
  of GamesPage, GamePage: result.action = PlayGame
  of ToolsPage: result = ViewTarget(action: ToolActions[state.tool], index: state.tool)
  of WorkbenchPage: result = ViewTarget(action: WorkbenchActions[state.workbench], index: state.workbench)
  of CollectionsPage: result = ViewTarget(action: ToggleCollection, index: state.collection)
  of AppearancePage: result.action = ApplyTheme
  of PowerPage: result.action = if state.confirmYes: ConfirmPower else: CancelDialog
  of ConflictPage: result.action = if state.confirmYes: UseRemoteSave else: UseLocalSave
  else: discard

proc beginAppearance*(state: var LibraryViewState) =
  ## Preview separately from the applied style and retain the page to return to.
  state.appearanceReturn = state.page
  state.previewTheme = state.theme
  state.page = AppearancePage

proc cancelAppearance*(state: var LibraryViewState) =
  ## Leave application and library state untouched when discarding a preview.
  state.previewTheme = state.theme
  state.page = state.appearanceReturn

proc applyAppearance*(state: var LibraryViewState, path: string) =
  ## Save before changing the active theme so write failures remain visible.
  saveTheme(path, state.previewTheme)
  state.theme = state.previewTheme
  state.page = state.theme.homePage()

proc cover(ui: LibraryUi, paths: LibraryPaths, game: LibraryGame): Image =
  ## Decode once and cap both source dimensions and the number of cached covers.
  if game.cover.len == 0: return
  let path = paths.root.inside(game.cover)
  if not fileExists(path): return
  if path notin ui.covers:
    if ui.covers.len >= MaximumCovers: ui.covers.clear()
    ui.covers[path] = nil
    try:
      let dimensions = readImageDimensions(path)
      if dimensions.width.int64 * dimensions.height.int64 > MaximumCoverPixels: return
      let
        original = readImage(path)
        scale = min(1'f32, min(CoverWidth.float32 / original.width.float32,
          CoverHeight.float32 / original.height.float32))
      ui.covers[path] = original.resize(max(1, int(original.width.float32 * scale)),
        max(1, int(original.height.float32 * scale)))
    except PixieError:
      return
  ui.covers[path]

proc drawCover(ui: LibraryUi, image: Image, paths: LibraryPaths,
    game: LibraryGame, area: UiRect) =
  ## Fit artwork without stretching and give missing artwork an intentional cover.
  if area.width <= 0 or area.height <= 0: return
  let cover = ui.cover(paths, game)
  if cover == nil:
    image.rect(area.x, area.y, area.width, area.height, ui.palette.surface)
    let inset = max(4, min(area.width, area.height) div 8)
    image.rect(area.x + inset, area.y + inset, max(1, area.width - inset * 2), 4, ui.palette.accent)
    ui.label(image, game.platform.toUpperAscii(), area.x + inset,
      area.y + area.height div 2 - 10, min(22, area.width div 4).float32, ui.palette.accent)
  else:
    let scale = min(area.width.float32 / cover.width.float32, area.height.float32 / cover.height.float32)
    image.draw(cover, translate(vec2(area.x.float32 + (area.width.float32 - cover.width.float32 * scale) / 2,
      area.y.float32 + (area.height.float32 - cover.height.float32 * scale) / 2)) * scale(vec2(scale)))

proc toolbar(ui: LibraryUi, image: Image, power: PowerStatus, title: string) =
  ## Preserve battery flow details in every theme, including plugged-in discharge.
  let
    p = ui.palette
    x = max(image.width div 2, image.width - 315)
    reading = power.selectedBattery()
    draining = power.external and power.batteryFlow() == DischargingFlow
    tint = if draining: 0xb25b21'u32 else: p.accent
  image.rect(0, 0, image.width, 64, p.surface)
  ui.label(image, title, 16, 23, if image.width < 500: 16 else: 22)
  image.rect(x, 25, 32, 18, p.muted)
  image.rect(x + 32, 30, 3, 8, p.muted)
  image.rect(x + 2, 27, 28, 14, p.background)
  if reading.percent >= 0: image.rect(x + 3, 28, 26 * reading.percent div 100, 12, tint)
  let available = max(5, (image.width - x - 50) div 8)
  ui.label(image, shortText(power.batteryText(), available), x + 44,
    if power.external: 10 else: 23, 16)
  if power.external:
    ui.label(image, shortText(power.chargeText(), available), x + 44, 36, 14,
      if draining: tint else: p.text)

proc button(ui: LibraryUi, image: Image, item: ViewTarget, text: string, active = false) =
  ## Paint a control in exactly its interactive rectangle.
  let area = item.area
  image.rect(area.x, area.y, area.width, area.height,
    if active: ui.palette.selected else: ui.palette.surface)
  if active: image.rect(area.x, area.y, 4, area.height, ui.palette.accent)
  let size = min(20, max(11, area.height - 12)).float32
  ui.label(image, shortText(text, max(4, int((area.width - 20).float32 / (size * 0.53)))),
    area.x + 10, area.y + (area.height - size.int) div 2 - 1, size)

proc drawDetails(ui: LibraryUi, image: Image, paths: LibraryPaths, game: LibraryGame) =
  ## Share readable game details across themes and paired displays.
  if game == nil:
    ui.label(image, "Your next game awaits", 24, 104, 24, ui.palette.accent)
    ui.label(image, "Add games locally or through RomM.", 24, 148, 16)
    return
  let
    width = image.width
    height = image.height
    narrow = width < 500
    coverWidth = if narrow: width div 3 else: width * 2 div 5
    left = coverWidth + 36
    textWidth = width - left - 20
    titleSize = if narrow: 19 else: 28
  ui.drawCover(image, paths, game, UiRect(x: 16, y: 90,
    width: coverWidth, height: max(30, height - 172)))
  var y = 100
  for line in game.title.wrapWords(max(8, textWidth div (titleSize div 2))).splitLines():
    if y < height - 90:
      ui.label(image, line, left, y, titleSize.float32)
      y += titleSize + 5
  for line in [game.platform.toUpperAscii(),
      if game.core.len > 0: game.core else: "No emulator configured",
      if game.favourite: "Favourite" else: "Y: Add favourite"]:
    if y < height - 80:
      ui.label(image, shortText(line, max(8, textWidth div 9)), left, y, 16, ui.palette.accent)
      y += 26
  for line in game.summary.wrapWords(max(10, textWidth div 9)).splitLines():
    if y < height - 80:
      ui.label(image, line, left, y, 16, ui.palette.muted)
      y += 23

proc systemIcon(ui: LibraryUi, image: Image, area: UiRect, platform: string) =
  ## Draw an original cartridge or dual-screen silhouette with simple shapes.
  let
    x = area.x
    y = area.y
    ink = ui.palette.accent
  image.rect(x, y, 24, 25, ink)
  image.rect(x + 4, y + 4, 16, if platform == "nds": 6 else: 12, ui.palette.surface)
  image.rect(x + 4, y + 15, 16, 6, ui.palette.surface)

proc renderLibrary*(ui: LibraryUi, paths: LibraryPaths, index: LibraryIndex,
    state: LibraryViewState, power: PowerStatus, width, height: int,
    detailsScreen: bool, systemLines: seq[string]): Image =
  ## Render a themed view; previews reuse this path without issuing app actions.
  let previousPalette = ui.palette
  ui.palette = ThemePalettes[state.theme]
  defer: ui.palette = previousPalette
  let
    p = ui.palette
    games = index.visibleGames(state.filter)
    game = if games.len > 0: games[clamp(state.selected, 0, games.high)] else: nil
    areas = state.pageLayout(index, width, height)
  result = newCanvas(width, height)
  result.fill(p.background)
  ui.toolbar(result, power, if state.theme == PocketTheme: "mono / pocket" else: "mono-retro")
  if state.page == AppearancePage:
    var preview = state
    preview.theme = state.previewTheme
    preview.page = preview.theme.homePage()
    preview.transition = 1
    preview.message = ""
    let image = ui.renderLibrary(paths, index, preview, power, width, height, detailsScreen, systemLines)
    if detailsScreen:
      result = image
      ui.toolbar(result, power, "Preview / " & ThemeNames[state.previewTheme])
    else:
      for item in areas.targets:
        if item.action == SelectTheme:
          ui.button(result, item, ThemeNames[MenuTheme(item.index)], item.index == ord(state.previewTheme))
        else:
          ui.button(result, item, if item.action == ApplyTheme: "A: Apply" else: "B: Cancel",
            item.action == ApplyTheme)
      let
        top = 142
        availableHeight = max(1, height - top - 80)
        scale = min((width - 32).float32 / width.float32, availableHeight.float32 / height.float32)
        previewWidth = max(1, int(width.float32 * scale))
        previewHeight = max(1, int(height.float32 * scale))
        thumbnail = image.resize(previewWidth, previewHeight)
      result.draw(thumbnail, translate(vec2(((width - previewWidth) div 2).float32, top.float32)))
      ui.label(result, shortText(ThemeDescriptions[state.previewTheme], max(12, (width - 32) div 8)),
        16, 116, 15, p.muted)
  elif state.page == WorkbenchPage:
    if detailsScreen:
      ui.label(result, "DEVICE WORKBENCH", 24, 88, 25, p.accent)
      var y = 142
      for line in systemLines:
        if y < height - 60:
          ui.label(result, shortText(line, max(10, (width - 48) div 10)), 24, y, 18, p.muted)
          y += 27
    else:
      ui.label(result, "Workbench", 16, 77, 22, p.accent)
      for position, item in areas.targets:
        ui.button(result, item, ActionLabels[item.action], position == state.workbench)
      ui.label(result, "A: Open   Start: Menu   B: Games", 16, height - 52, 14, p.muted)
  elif detailsScreen or state.page == GamePage:
    ui.drawDetails(result, paths, game)
    if state.page == GamePage and not detailsScreen:
      for item in areas.targets: ui.button(result, item, if item.action == PlayGame: "A: Play" else: "B: Back")
  elif state.page == GamesPage:
    let
      choices = index.filters()
      layout = themeLayout(state.theme, width, height, state.selected, games.len)
    if state.theme == PocketTheme:
      for item in areas.targets:
        if item.action == SelectFilter:
          ui.button(result, item, choices[item.index], item.index == state.filter)
    else:
      ui.label(result, "‹ " & choices[state.filter] & " ›", 24, 77, 18, p.accent)
    if state.theme != PocketTheme:
      ui.label(result, $games.len & " games", max(24, width - 95), 79, 15, p.muted)
    if state.theme == ShowcaseTheme and game != nil:
      let
        hero = layout.hero
        artWidth = min(hero.width div 2, hero.height * 3 div 4)
        left = hero.x + artWidth + 20
        textWidth = width - left - 20
      ui.drawCover(result, paths, game, UiRect(x: hero.x, y: hero.y, width: artWidth, height: hero.height))
      var y = hero.y + 10
      for line in game.title.wrapWords(max(9, textWidth div 12)).splitLines():
        if y < hero.y + hero.height - 24:
          ui.label(result, line, left, y, if width < 500: 19 else: 27)
          y += 33
      if y + 24 < hero.y + hero.height:
        ui.label(result, game.platform.toUpperAscii(), left, y + 6, 16, p.accent)
    for position, area in layout.cards:
      let
        number = layout.first + position
        item = games[number]
        active = number == state.selected
        textOnly = area.height < 70
      result.rect(area.x, area.y, area.width, area.height, if active: p.selected else: p.surface)
      if state.theme == PocketTheme and not textOnly:
        result.rect(area.x, area.y, 5, area.height, p.accent)
        ui.systemIcon(result, UiRect(x: area.x + 12, y: area.y + 12), item.platform)
      if active:
        result.rect(area.x, area.y + area.height - 3,
          max(1, int(area.width.float32 * state.transition)), 3, p.accent)
      if not textOnly:
        ui.drawCover(result, paths, item, UiRect(x: area.x + 7, y: area.y + 7,
          width: area.width - 14, height: max(1, area.height - (if state.theme == PocketTheme: 65 else: 45))))
      if state.theme == PocketTheme and area.height > 85:
        ui.label(result, item.platform.toUpperAscii() & (if item.core.len == 0: " / No emulator" else: ""),
          area.x + 12, area.y + area.height - 48, 12, p.accent)
      ui.label(result, shortText(item.title, max(5, (area.width - 14) div 8)),
        area.x + 7, area.y + (if textOnly: max(2, (area.height - 16) div 2) else: area.height - 28), 15)
      if item.favourite and not textOnly:
        ui.label(result, "★", area.x + area.width - 25, area.y + 10, 18, p.accent)
    for item in areas.targets:
      if item.action == PlayGame:
        ui.button(result, item, if state.busy: "Working…" elif width < 500: "A: Play" else: "A: Play   X: Details")
      elif item.action == ShowTools:
        ui.button(result, item, if width < 500: "Start: Menu" else: "Start: Menu   Y: Favourite")
    if games.len == 0: ui.label(result, "No games in this view", 24, height div 2, 20, p.muted)
  elif state.page in {ToolsPage, CollectionsPage}:
    ui.label(result, if state.page == ToolsPage: "Menu" else: "RomM collections", 24, 80, 23, p.accent)
    for item in areas.targets:
      let
        text = if state.page == ToolsPage: ActionLabels[item.action] else:
          (if index.collections[item.index].selected: "✓ " else: "○ ") & index.collections[item.index].name
        active = item.index == (if state.page == ToolsPage: state.tool else: state.collection)
      ui.button(result, item, text, active)
    if areas.targets.len == 0:
      ui.label(result, "Create a collection in RomM, then Sync now.", 24, 150, 16, p.muted)
  elif state.page == SystemPage:
    var y = 86
    for line in systemLines[max(0, min(state.scroll, systemLines.len)) ..< systemLines.len]:
      if y < height - 80: ui.label(result, shortText(line, max(10, (width - 48) div 9)), 24, y, 17, p.muted)
      y += 25
  elif state.page == PairPage:
    ui.label(result, "Connect to RomM", 24, 92, 26, p.accent)
    var y = 144
    for line in state.message.splitLines():
      for wrapped in line.wrapWords(max(15, (width - 48) div 12)).splitLines():
        ui.label(result, wrapped, 24, y, 20)
        y += 30
    ui.label(result, "Approve in your browser. B cancels.", 24, height - 74, 16, p.muted)
  elif state.page in {PowerPage, ConflictPage}:
    let powerPage = state.page == PowerPage
    ui.label(result, if powerPage:
      (if state.reboot: "Reboot this device?" else: "Shut down this device?") else:
      "Two versions of your save", 24, 100, if width < 500: 22 else: 28, p.accent)
    ui.label(result, if powerPage: "Choose Cancel to return." else:
      "Both versions will be preserved.", 24, 144, 16, p.muted)
    for position, item in areas.targets:
      ui.button(result, item, ActionLabels[item.action], (position == 1) == state.confirmYes)
  if state.message.len > 0 and state.page notin {PairPage, AppearancePage}:
    ui.label(result, shortText(state.message.splitLines()[0], max(10, (width - 32) div 8)),
      16, height - 20, 14, if state.error: 0xc95138'u32 else: p.muted)
