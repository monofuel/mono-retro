import
  std/[algorithm, os, strutils, tables, unicode, wordwrap],
  pixie,
  ../touchkeyboard,
  ./[bluetooth, gamelibrary, launcherui, menuthemes, pattern, systeminfo, wifi]

type
  LibraryPage* = enum
    GamesPage, ToolsPage, CollectionsPage, GamePage, SystemPage, PairPage,
    PowerPage, ConflictPage, WorkbenchPage, AppearancePage, SettingsPage,
    WifiPage, WifiPasswordPage, WifiConfirmPage, BluetoothPage, BluetoothDevicePage,
    BluetoothPromptPage, BluetoothKeyboardPage, BluetoothForgetPage, AudioUnavailablePage
  ViewAction* = enum
    NoViewAction, SelectGame, PlayGame, ShowGames, ShowTools, TestHardware,
    ShowSystem, ShowCollections, ConnectRomm, OpenRommLink, SyncRomm, DisconnectRomm,
    RebootDevice, ShutdownDevice, RescanGames, ShowAppearance, SelectTheme,
    ApplyTheme, CancelAppearance, PreviousFilter, NextFilter, ToggleCollection,
    CancelDialog, ConfirmPower, UseLocalSave, UseRemoteSave, SelectFilter,
    ShowSettings, ShowWifi, SelectWifiNetwork, RescanWifi, ConnectWifi, CancelWifi,
    OpenGrimoire, ShowBluetooth, SelectBluetoothDevice, ScanBluetooth,
    PowerBluetooth, ConnectBluetooth, DisconnectBluetooth, ForgetBluetooth,
    ConfirmForgetBluetooth, UseBluetoothAudio, UseSpeakerAudio, ReturnBluetooth,
    AcceptBluetoothPrompt, RejectBluetoothPrompt, RetryAudio, SpeakerAudio, CancelAudio
  ViewTarget* = object
    area*: UiRect
    action*: ViewAction
    index*: int
  WifiView* = object
    ## Wi-Fi settings data shown by the view; filled by the launcher's worker.
    status*: WifiStatus
    networks*: seq[WifiNetwork]
    selected*: int
    message*: string
    error*, busy*, connecting*, unavailable*: bool
    keyboard*: TouchKeyboard
  BluetoothView* = object
    state*: BtState
    selected*, action*: int
    device*: BtDevice
    audioAddress*, audioName*: string
    keyboard*: TouchKeyboard
    confirm*: bool
    message*: string
  LibraryViewState* = object
    page*, appearanceReturn*: LibraryPage
    theme*, previewTheme*: MenuTheme
    selected*, tool*, collection*, filter*, scroll*, workbench*, setting*: int
    wifi*: WifiView
    bluetooth*: BluetoothView
    message*, pairingUrl*: string
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
  GrimoireApplicationHash* = "app:grimoire"
  GrimoireCoverPath = "/usr/local/share/grimoire/cover.png"
  CoverWidth = 360
  CoverHeight = 480
  MaximumCoverPixels = 4_000_000
  WorkbenchFooterHeight = 64
  ToolActions* = [TestHardware, ShowSystem, ShowAppearance, ShowSettings, ShowCollections,
    ConnectRomm, SyncRomm, DisconnectRomm, RebootDevice, ShutdownDevice, RescanGames]
  WorkbenchActions* = [TestHardware, ShowSystem, ShowGames, SyncRomm, ShowAppearance,
    ShowSettings, ShowTools]
  SettingsActions* = [ShowWifi, ShowBluetooth, ShowAppearance]
  MinimumWorkbenchItem = 30
  WifiListTop = 150
  ListRowHeight = 38
  ListRowStep = 43
  ActionLabels*: array[ViewAction, string] = ["", "", "Play", "Games", "Menu",
    "Hardware Test", "System Info", "RomM collections", "Connect to RomM", "Open in browser",
    "Sync now", "Disconnect RomM", "Reboot", "Shut down", "Rescan games",
    "Appearance", "", "Apply", "Cancel", "Previous filter", "Next filter", "",
    "Cancel", "Confirm", "Local save", "RomM save", "", "Settings", "Wi-Fi", "",
    "Scan", "Connect", "Cancel", "Grimoire", "Bluetooth", "", "Scan",
    "Power", "Connect", "Disconnect", "Forget", "Forget", "Use for audio",
    "Use speakers", "Back", "Confirm", "Cancel", "Retry", "Use speakers", "Cancel"]
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

proc withApplications*(index: LibraryIndex, config: LibraryConfig): LibraryIndex =
  ## Present installed apps as launch cards without putting them in the ROM index.
  result = index
  result.games = @[]
  if config.grimoireCommand.len > 0:
    result.games.add LibraryGame(hash: GrimoireApplicationHash, title: "Grimoire",
      platform: "app", core: "Grimoire", summary: "Voice and touch ACP client.")
  result.games.add index.games

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

proc bluetoothDevice*(view: BluetoothView): BtDevice =
  ## Keep the selected identity stable when discovery changes the list order.
  for device in view.state.devices:
    if device.address == view.device.address: return device
  result = view.device
  result.connected = false
  result.audioReady = false
  result.gamepadReady = false

proc bluetoothActions*(view: BluetoothView): seq[ViewAction] =
  ## Offer actions supported by the current device's confirmed state.
  let device = view.bluetoothDevice()
  result.add if device.connected: DisconnectBluetooth else: ConnectBluetooth
  if device.audioReady: result.add UseBluetoothAudio
  if device.paired: result.add ForgetBluetooth
  result.add ReturnBluetooth

proc pairingLines*(text: string, width, height: int): seq[string] =
  ## Wrap the approval link using the same compact/desktop metrics as its hit target.
  for line in text.splitLines():
    result.add line.wrapWords(max(12, (width - 48) div (if height < 300: 8 else: 12))).splitLines()

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
    let twoColumnRows = (WorkbenchActions.len + result.columns - 1) div result.columns
    if result.columns == 2 and (height - 108 - WorkbenchFooterHeight - 10 * (twoColumnRows - 1)) div
        twoColumnRows < MinimumWorkbenchItem:
      result.columns = 3
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
  of SettingsPage:
    for item, action in SettingsActions:
      result.targets.add target(UiRect(x: 16, y: 115 + item * ListRowStep,
        width: width - 32, height: ListRowHeight), action, item)
  of BluetoothPage:
    let
      rows = max(1, (height - 196) div ListRowStep)
      first = max(0, state.bluetooth.selected - rows + 1)
      count = state.bluetooth.state.devices.len + 1
    for item in first ..< min(count, first + rows):
      result.targets.add target(UiRect(x: 16, y: 128 + (item - first) * ListRowStep,
        width: width - 32, height: ListRowHeight),
        if item == 0: UseSpeakerAudio else: SelectBluetoothDevice, item - 1)
    let buttonWidth = (width - 48) div 3
    for position, action in [ScanBluetooth, PowerBluetooth, ShowSettings]:
      result.targets.add target(UiRect(x: 16 + position * (buttonWidth + 8),
        y: height - 60, width: buttonWidth, height: 38), action)
  of BluetoothDevicePage:
    let
      actions = state.bluetooth.bluetoothActions()
      rows = max(1, (height - 174) div ListRowStep)
      selection = clamp(state.bluetooth.action, 0, actions.high)
      first = max(0, selection - rows + 1)
    for item in first ..< min(actions.len, first + rows):
      result.targets.add target(UiRect(x: 16, y: 128 + (item - first) * ListRowStep,
        width: width - 32, height: ListRowHeight), actions[item], item)
  of BluetoothPromptPage, BluetoothForgetPage:
    let footer = themeLayout(state.theme, width, height, 0, 0)
    result.targets.add target(footer.play, if state.page == BluetoothForgetPage:
      ReturnBluetooth else: RejectBluetoothPrompt)
    if state.page == BluetoothForgetPage or state.bluetooth.state.prompt.kind == ConfirmPrompt:
      result.targets.add target(footer.tools, if state.page == BluetoothForgetPage:
        ConfirmForgetBluetooth else: AcceptBluetoothPrompt)
  of AudioUnavailablePage:
    let
      top = if height < 300: 128 else: 150
      rowHeight = if height < 300: 28 else: 38
    for position, action in [RetryAudio, SpeakerAudio, CancelAudio]:
      result.targets.add target(UiRect(x: 16, y: top + position * (rowHeight + 8),
        width: width - 32, height: rowHeight), action, position)
  of WifiPage:
    let
      footer = themeLayout(state.theme, width, height, 0, 0)
      rows = max(1, (footer.play.y - 8 - WifiListTop) div ListRowStep)
      first = max(0, state.wifi.selected - rows + 1)
    for item in first ..< min(state.wifi.networks.len, first + rows):
      result.targets.add target(UiRect(x: 16, y: WifiListTop + (item - first) * ListRowStep,
        width: width - 32, height: ListRowHeight), SelectWifiNetwork, item)
    result.targets.add target(footer.play, RescanWifi)
    result.targets.add target(footer.tools, ShowSettings)
  of WifiConfirmPage:
    let footer = themeLayout(state.theme, width, height, 0, 0)
    result.targets.add target(footer.play, ConnectWifi)
    result.targets.add target(footer.tools, CancelWifi)
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
  of PairPage:
    if state.pairingUrl.len > 0:
      let
        top = if height < 300: 110 else: 144
        step = if height < 300: 20 else: 30
        footer = height - (if height < 300: 42 else: 74)
        rows = state.pairingUrl.pairingLines(width, height).len
      result.targets.add target(UiRect(x: 24, y: top - 4, width: max(1, width - 48),
        height: max(1, min(rows * step + 8, footer - top - 8))), OpenRommLink)
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
  of SettingsPage: state.setting = clamp(state.setting + direction, 0, SettingsActions.high)
  of WifiPage: state.wifi.selected = clamp(state.wifi.selected + direction, 0, max(0, state.wifi.networks.high))
  of BluetoothPage:
    state.bluetooth.selected = clamp(state.bluetooth.selected + direction, 0, state.bluetooth.state.devices.len)
  of BluetoothDevicePage:
    state.bluetooth.action = clamp(state.bluetooth.action + direction, 0, state.bluetooth.bluetoothActions().high)
  of BluetoothPromptPage, BluetoothForgetPage: state.bluetooth.confirm = direction > 0
  of AudioUnavailablePage: state.bluetooth.action = clamp(state.bluetooth.action + direction, 0, 2)
  else: discard

proc keyboardArea*(width, height: int): Rect =
  ## Place the password keyboard below the toolbar on the touch screen.
  rect(0, 64, width.float32, max(1, height - 64).float32)

proc selectedTarget*(state: LibraryViewState): ViewTarget =
  ## Translate controller confirmation into the same action as a visible button.
  case state.page
  of GamesPage, GamePage: result.action = PlayGame
  of ToolsPage: result = ViewTarget(action: ToolActions[state.tool], index: state.tool)
  of WorkbenchPage: result = ViewTarget(action: WorkbenchActions[state.workbench], index: state.workbench)
  of CollectionsPage: result = ViewTarget(action: ToggleCollection, index: state.collection)
  of AppearancePage: result.action = ApplyTheme
  of PairPage:
    if state.pairingUrl.len > 0: result.action = OpenRommLink
  of PowerPage: result.action = if state.confirmYes: ConfirmPower else: CancelDialog
  of ConflictPage: result.action = if state.confirmYes: UseRemoteSave else: UseLocalSave
  of SettingsPage: result = ViewTarget(action: SettingsActions[state.setting], index: state.setting)
  of WifiPage:
    result = if state.wifi.networks.len > 0:
      ViewTarget(action: SelectWifiNetwork, index: state.wifi.selected) else: ViewTarget(action: RescanWifi)
  of WifiConfirmPage: result.action = ConnectWifi
  of BluetoothPage:
    result = ViewTarget(action: if state.bluetooth.selected == 0: UseSpeakerAudio else: SelectBluetoothDevice,
      index: state.bluetooth.selected - 1)
  of BluetoothDevicePage:
    let actions = state.bluetooth.bluetoothActions()
    let selection = clamp(state.bluetooth.action, 0, actions.high)
    result = ViewTarget(action: actions[selection], index: selection)
  of BluetoothPromptPage:
    result.action = if state.bluetooth.confirm and state.bluetooth.state.prompt.kind == ConfirmPrompt:
      AcceptBluetoothPrompt else: RejectBluetoothPrompt
  of BluetoothForgetPage:
    result.action = if state.bluetooth.confirm: ConfirmForgetBluetooth else: ReturnBluetooth
  of AudioUnavailablePage:
    result.action = [RetryAudio, SpeakerAudio, CancelAudio][clamp(state.bluetooth.action, 0, 2)]
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

proc coverPath*(paths: LibraryPaths, game: LibraryGame): string =
  ## Resolve the installed app asset separately from card-relative game artwork.
  if game.hash == GrimoireApplicationHash: GrimoireCoverPath
  elif game.cover.len > 0: paths.root.inside(game.cover)
  else: ""

proc cover(ui: LibraryUi, paths: LibraryPaths, game: LibraryGame): Image =
  ## Decode once and cap both source dimensions and the number of cached covers.
  let path = paths.coverPath(game)
  if path.len == 0 or not fileExists(path): return
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
  if power.batteries.len == 0: return
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
      if game.hash == GrimoireApplicationHash: "Application"
      elif game.favourite: "Favourite" else: "Y: Add favourite"]:
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

proc tint(value: uint32): chroma.Color =
  ## Convert a packed RGB theme colour.
  color(float32(value shr 16 and 255) / 255, float32(value shr 8 and 255) / 255,
    float32(value and 255) / 255, 1)

proc keyboardTheme*(palette: ThemePalette): KeyboardTheme =
  ## Derive keyboard colours from a launcher theme.
  KeyboardTheme(background: tint(palette.background), field: tint(palette.surface),
    key: tint(palette.surface), special: mix(tint(palette.surface), tint(palette.background), 0.5),
    focused: tint(palette.selected), text: tint(palette.text), muted: tint(palette.muted),
    accent: tint(palette.accent))

proc signalPercent*(network: WifiNetwork): int =
  ## Approximate signal quality from dBm for display.
  clamp(2 * (network.signal + 100), 0, 100)

proc wifiStatusLines*(view: WifiView): seq[string] =
  ## Describe the current connection in short display lines.
  if view.unavailable: return @["Wi-Fi unavailable on this device"]
  let status = view.status
  result.add(if status.state == "COMPLETED": "Connected to " & status.ssid
    elif status.state.len == 0: "Checking Wi-Fi…"
    else: "Not connected (" & status.state.toLowerAscii() & ")")
  if status.ipAddress.len > 0: result.add "Address " & status.ipAddress

proc networkNote(network: WifiNetwork): string =
  ## Summarize security and saved state for a list row.
  let kind = if network.security notin SupportedSecurity: "Unsupported"
    elif network.savedId >= 0: "Saved"
    elif network.security == OpenSecurity: "Open"
    else: "Password"
  kind & "  " & $network.signalPercent() & "%"

proc drawWifi(ui: LibraryUi, image: Image, state: LibraryViewState,
    areas: PageLayout, width, height: int, detailsScreen: bool) =
  ## Render Settings and Wi-Fi pages; the details screen carries status and progress.
  let
    p = ui.palette
    view = state.wifi
    network = if view.networks.len > 0: view.networks[clamp(view.selected, 0, view.networks.high)]
      else: WifiNetwork(savedId: -1)
    characters = max(10, (width - 48) div 10)
  if detailsScreen:
    ui.label(image, "WI-FI", 24, 88, 25, p.accent)
    var y = 136
    for line in view.wifiStatusLines():
      ui.label(image, shortText(line, characters), 24, y, 18)
      y += 27
    if state.page in {WifiPage, WifiConfirmPage, WifiPasswordPage} and network.ssid.len > 0:
      y += 14
      for line in [network.ssid, SecurityNames[network.security],
          "Signal " & $network.signalPercent() & "%  " &
            (if network.frequency >= 5925: "6 GHz" elif network.frequency >= 4900: "5 GHz" else: "2.4 GHz"),
          if network.savedId >= 0: "Saved on this device" else: "Not saved yet"]:
        if y < height - 70:
          ui.label(image, shortText(line, characters), 24, y, 17, p.muted)
          y += 25
    if state.page == WifiPasswordPage and y < height - 70:
      ui.label(image, "8-63 characters, or a 64-digit hex key.", 24, y + 8, 15, p.muted)
      if y + 33 < height - 70: ui.label(image, "Hidden unless you choose Show.", 24, y + 33, 15, p.muted)
    if view.message.len > 0:
      ui.label(image, shortText(view.message, characters), 24, height - 40, 16,
        if view.error: 0xc95138'u32 else: p.accent)
    return
  case state.page
  of SettingsPage:
    ui.label(image, "Settings", 24, 80, 23, p.accent)
    for item in areas.targets: ui.button(image, item, ActionLabels[item.action], item.index == state.setting)
  of WifiPage:
    ui.label(image, "Wi-Fi", 24, 80, 23, p.accent)
    let statusLines = view.wifiStatusLines()
    ui.label(image, shortText(statusLines.join("  ·  "), max(10, (width - 48) div 8)), 24, 116, 15, p.muted)
    for item in areas.targets:
      case item.action
      of SelectWifiNetwork:
        let entry = view.networks[item.index]
        ui.button(image, ViewTarget(area: UiRect(x: item.area.x, y: item.area.y,
          width: max(1, item.area.width - 130), height: item.area.height)),
          (if entry.current: "• " else: "") & entry.ssid, item.index == view.selected)
        image.rect(item.area.x + item.area.width - 130, item.area.y, 130, item.area.height,
          if item.index == view.selected: p.selected else: p.surface)
        ui.label(image, entry.networkNote(), item.area.x + item.area.width - 122,
          item.area.y + (item.area.height - 14) div 2 - 1, 13,
          if entry.security in SupportedSecurity: p.muted else: 0xc95138'u32)
      of RescanWifi:
        ui.button(image, item, if view.connecting: "Connecting…" elif view.busy: "Checking…"
          elif width < 500: "X: Scan" else: "X: Scan   A: Join")
      else: ui.button(image, item, if view.connecting: "B: Cancel" else: "B: Back")
    if view.networks.len == 0:
      ui.label(image, if view.busy: "Looking for networks…" elif view.unavailable: "Wi-Fi manager not found"
        else: "No networks found. Choose Scan.", 24, WifiListTop + 10, 17, p.muted)
  of WifiConfirmPage:
    ui.label(image, shortText("Join " & network.ssid & "?", max(10, (width - 48) div 13)),
      24, 92, if width < 500: 21 else: 26, p.accent)
    ui.label(image, if network.savedId >= 0: "Uses the profile saved on this device." else: "Open network; no password.",
      24, 138, 16, p.muted)
    ui.label(image, "Your current connection returns if this fails.", 24, 164, 15, p.muted)
    for item in areas.targets:
      ui.button(image, item, if item.action == ConnectWifi: "A: Connect" else: "B: Cancel",
        item.action == ConnectWifi)
  of WifiPasswordPage:
    let area = keyboardArea(width, height)
    view.keyboard.render(image, view.keyboard.keyboardLayout(area), ui.text.font,
      keyboardTheme(p))
  else: discard
  if view.message.len > 0 and state.page notin {SettingsPage, WifiPasswordPage}:
    ui.label(image, shortText(view.message, max(10, (width - 32) div 8)), 16, height - 20, 14,
      if view.error: 0xc95138'u32 else: p.muted)

proc drawBluetooth(ui: LibraryUi, image: Image, state: LibraryViewState,
    areas: PageLayout, detailsScreen: bool) =
  ## Share Bluetooth state across themes while keeping touch controls below.
  let
    view = state.bluetooth
    device = view.bluetoothDevice()
    p = ui.palette
    width = image.width
    height = image.height
    characters = max(12, (width - 48) div 9)
    status = if not view.state.available: "Bluetooth unavailable"
      elif not view.state.powered: "Bluetooth off"
      elif view.state.discovering: "Scanning…" else: "Bluetooth on"
    output = if view.audioAddress.len == 0: "Speakers" else: view.audioName
    message = if view.message.len > 0: view.message
      elif view.state.error.len > 0: view.state.error else: view.state.message
  if detailsScreen:
    ui.label(image, "BLUETOOTH", 24, 88, 25, p.accent)
    var y = 138
    var lines = @[status, "New apps use: " & output]
    if device.address.len > 0:
      lines.add @[device.name, device.address,
        if device.connected: "Connected" elif device.paired: "Paired" else: "Not paired",
        if device.audioReady: "Headphone audio ready" elif device.gamepadReady:
          "Controller input ready" else: "No active audio/input profile"]
      if device.batteryPercent >= 0: lines.add "Device battery: " & $device.batteryPercent & "%"
    if state.page in {BluetoothPromptPage, BluetoothKeyboardPage}:
      lines.add view.state.prompt.text
      if view.state.prompt.code.len > 0: lines.add view.state.prompt.code
    if message.len > 0: lines.add message
    for line in lines:
      for wrapped in line.wrapWords(characters).splitLines():
        if y < height - 36:
          ui.label(image, wrapped, 24, y, 17, p.text)
          y += 25
    return
  case state.page
  of BluetoothPage:
    ui.label(image, "Bluetooth", 24, 78, 22, p.accent)
    ui.label(image, shortText(status & " · Audio: " & output, characters), 24, 106, 14, p.muted)
    for item in areas.targets:
      let text = case item.action
        of UseSpeakerAudio: "Use speakers for new apps"
        of SelectBluetoothDevice:
          let entry = view.state.devices[item.index]
          (if entry.connected: "• " elif entry.paired: "✓ " else: "") &
            (if entry.name.len > 0: entry.name else: entry.address)
        of ScanBluetooth: "X: Scan"
        of PowerBluetooth: (if view.state.powered: "Y: Turn off" else: "Y: Turn on")
        else: "Back"
      ui.button(image, item, text, (item.action == UseSpeakerAudio and view.selected == 0) or
        (item.action == SelectBluetoothDevice and item.index + 1 == view.selected))
  of BluetoothDevicePage:
    ui.label(image, shortText(device.name, characters), 24, 80, 22, p.accent)
    let connection = if device.audioReady: "Headphone audio ready"
      elif device.gamepadReady: "Controller input ready"
      elif device.connected: "Connected; profile not ready"
      elif device.paired: "Paired; disconnected" else: "Not paired"
    ui.label(image, shortText(connection, characters), 24, 108, 14, p.muted)
    for item in areas.targets:
      let text = if item.action == ConnectBluetooth and not device.paired: "Pair and connect"
        else: ActionLabels[item.action]
      ui.button(image, item, text, item.index == view.action)
  of BluetoothKeyboardPage:
    view.keyboard.render(image, view.keyboard.keyboardLayout(keyboardArea(width, height)),
      ui.text.font, keyboardTheme(p))
  of BluetoothPromptPage, BluetoothForgetPage:
    ui.label(image, if state.page == BluetoothForgetPage: "Forget this device?"
      elif view.state.prompt.kind == ConfirmPrompt:
        (if view.state.prompt.code.len > 0: "Do both codes match?" else: "Allow this device?")
      else: "Enter this on your device", 24, 82, if width < 500: 20 else: 25, p.accent)
    ui.label(image, if state.page == BluetoothForgetPage: shortText(device.name, characters)
      elif view.state.prompt.code.len > 0: view.state.prompt.code
      else: shortText(view.state.prompt.text, characters), 24, 124, 25, p.text)
    for item in areas.targets:
      let affirmative = item.action in {ConfirmForgetBluetooth, AcceptBluetoothPrompt}
      ui.button(image, item, if affirmative: "Confirm" else: "Cancel",
        affirmative == view.confirm)
  of AudioUnavailablePage:
    ui.label(image, "Headphones unavailable", 24, 77, if width < 500: 20 else: 24, p.accent)
    ui.label(image, shortText(message, characters), 24, 108, 14, p.muted)
    for item in areas.targets:
      ui.button(image, item, ActionLabels[item.action], item.index == view.action)
  else: discard
  if message.len > 0 and state.page notin {BluetoothKeyboardPage, AudioUnavailablePage}:
    ui.label(image, shortText(message, max(12, (width - 32) div 8)), 16, height - 20, 14,
      if view.state.error.len > 0: 0xc95138'u32 else: p.muted)

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
  ui.toolbar(result, power, if state.page == WifiPasswordPage and state.wifi.networks.len > 0:
    shortText("Password: " & state.wifi.networks[clamp(state.wifi.selected, 0,
      state.wifi.networks.high)].ssid, max(8, width div 22))
    elif state.theme == PocketTheme: "mono / pocket" else: "mono-retro")
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
  elif state.page in {SettingsPage, WifiPage, WifiConfirmPage, WifiPasswordPage}:
    ui.drawWifi(result, state, areas, width, height, detailsScreen)
  elif state.page in {BluetoothPage, BluetoothDevicePage, BluetoothPromptPage,
      BluetoothKeyboardPage, BluetoothForgetPage, AudioUnavailablePage}:
    ui.drawBluetooth(result, state, areas, detailsScreen)
  elif detailsScreen or state.page == GamePage:
    ui.drawDetails(result, paths, game)
    if state.page == GamePage and not detailsScreen:
      for item in areas.targets:
        ui.button(result, item, if item.action != PlayGame: "B: Back"
          elif game != nil and game.hash == GrimoireApplicationHash: "A: Open"
          else: "A: Play")
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
        ui.button(result, item, if state.busy: "Working…"
          elif game != nil and game.hash == GrimoireApplicationHash: "A: Open"
          elif width < 500: "A: Play" else: "A: Play   X: Details")
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
    let
      compact = height < 300
      footer = height - (if compact: 42 else: 74)
      clickable = state.pairingUrl.len > 0
    ui.label(result, "Connect to RomM", 24, if compact: 80 else: 92,
      if compact: 20 else: 26, p.accent)
    var y = if compact: 110 else: 144
    for wrapped in (if clickable: state.pairingUrl else: state.message).pairingLines(width, height):
      if y + (if compact: 14 else: 20) < footer - 8:
        ui.label(result, wrapped, 24, y, if compact: 14 else: 20,
          if clickable: p.accent else: p.text)
      y += (if compact: 20 else: 30)
    if clickable:
      let area = areas.targets[0].area
      result.rect(area.x, area.y + area.height - 1, area.width, 1, p.accent)
    ui.label(result, if clickable and state.error:
      shortText(state.message, max(12, (width - 48) div (if compact: 8 else: 9)))
      elif clickable: (if compact: "Click / A: browser. B: cancel" else:
      "Click link or press A/Enter. B cancels.") else:
      "Approve in your browser. B cancels.", 24, footer, if compact: 14 else: 16, p.muted)
  elif state.page in {PowerPage, ConflictPage}:
    let powerPage = state.page == PowerPage
    ui.label(result, if powerPage:
      (if state.reboot: "Reboot this device?" else: "Shut down this device?") else:
      "Two versions of your save", 24, 100, if width < 500: 22 else: 28, p.accent)
    ui.label(result, if powerPage: "Choose Cancel to return." else:
      "Both versions will be preserved.", 24, 144, 16, p.muted)
    for position, item in areas.targets:
      ui.button(result, item, ActionLabels[item.action], (position == 1) == state.confirmYes)
  if state.message.len > 0 and state.page notin {PairPage, AppearancePage, SettingsPage, WifiPage,
      WifiConfirmPage, WifiPasswordPage, BluetoothPage, BluetoothDevicePage,
      BluetoothPromptPage, BluetoothKeyboardPage, BluetoothForgetPage, AudioUnavailablePage}:
    ui.label(result, shortText(state.message.splitLines()[0], max(10, (width - 32) div 8)),
      16, height - 20, 14, if state.error: 0xc95138'u32 else: p.muted)
