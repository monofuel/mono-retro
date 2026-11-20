import
  std/[os, strutils, tempfiles],
  pixie,
  touchkeyboard,
  retro/[gamelibrary, launcherui, libraryview, menuthemes, pattern, systeminfo, wifi]

proc testWifiPages(ui: LibraryUi, paths: LibraryPaths, index: LibraryIndex, power: PowerStatus) =
  ## Render Settings and Wi-Fi pages in every theme with shared touch targets.
  doAssert ShowSettings in ToolActions and ShowSettings in WorkbenchActions
  var wifi = WifiView(status: WifiStatus(state: "COMPLETED", ssid: "Home", ipAddress: "192.0.2.10",
    networkId: 0), message: "Connecting to ☕ café")
  for number, (name, security, saved) in [("Home", PersonalSecurity, 0), ("☕ café", PersonalSecurity, -1),
      ("Library guest", OpenSecurity, -1), ("Office", EnterpriseSecurity, -1),
      ("A network name that is exactly long", Wpa3OnlySecurity, -1), ("Six", PersonalSecurity, -1),
      ("Seven", OpenSecurity, -1), ("Eight", PersonalSecurity, -1)]:
    wifi.networks.add WifiNetwork(ssid: name, ssidHex: name.ssidToHex(), signal: -40 - number * 6,
      frequency: if number mod 2 == 0: 2412 else: 5180, security: security, savedId: saved,
      current: number == 0)
  wifi.selected = 1
  wifi.keyboard = newTouchKeyboard("hunter22", label = "Password", submitLabel = "Connect")
  for theme in MenuTheme:
    for page in [SettingsPage, WifiPage, WifiConfirmPage, WifiPasswordPage]:
      var state = LibraryViewState(page: page, theme: theme, previewTheme: theme, transition: 1, wifi: wifi)
      for dimensions in [(640, 480), (720, 480), (320, 240), (1024, 768)]:
        let layout = state.pageLayout(index, dimensions[0], dimensions[1])
        for item in layout.targets:
          let area = item.area
          doAssert area.x >= 0 and area.y >= 0 and area.width > 0 and area.height > 0
          doAssert area.x + area.width <= dimensions[0] and area.y + area.height <= dimensions[1]
          doAssert layout.hitTarget(vec2((area.x + area.width div 2).float32,
            (area.y + area.height div 2).float32)).action == item.action
        if page == WifiPage and dimensions[1] >= 480:
          doAssert layout.hitTarget(vec2(30, 150 + 43 + 10)).index == 1
        for top in [false, true]:
          discard ui.renderLibrary(paths, index, state, power, dimensions[0], dimensions[1], top, @[])
      let
        top = ui.renderLibrary(paths, index, state, power, 640, 480, true, @[])
        bottom = ui.renderLibrary(paths, index, state, power, 640, 480, false, @[])
        pair = newCanvas(640, 968)
      pair.fill(0x030609'u32)
      pair.draw(top)
      pair.draw(bottom, translate(vec2(0, 488)))
      pair.writeFile("build/wifi-" & ThemeKeys[theme] & "-" & ($page).toLowerAscii() & ".png")
  var state = LibraryViewState(page: SettingsPage, theme: LibraryTheme, wifi: wifi)
  doAssert state.selectedTarget().action == ShowWifi
  state.moveSelection(index, 640, 480, 1, true)
  doAssert state.selectedTarget().action == ShowAppearance
  state.page = WifiPage
  state.moveSelection(index, 640, 480, 1, true)
  doAssert state.selectedTarget().action == SelectWifiNetwork and state.selectedTarget().index == 2
  state.wifi.networks.setLen(0)
  doAssert state.selectedTarget().action == RescanWifi
  let area = keyboardArea(640, 480)
  doAssert area.y >= 64 and area.y + area.h <= 480
  for key in wifi.keyboard.keyboardLayout(area).keys: doAssert key.area.h >= 50

proc testGrimoireApp(ui: LibraryUi, paths: LibraryPaths, index: LibraryIndex, power: PowerStatus) =
  ## Present Grimoire beside games without persisting an application as a ROM.
  doAssert ToolActions[2] == ShowAppearance and ToolActions[3] == ShowSettings
  doAssert OpenGrimoire notin ToolActions and OpenGrimoire notin SettingsActions
  let
    originalCount = index.games.len
    presented = index.withApplications(LibraryConfig(grimoireCommand: @["/fixture/grimoire"]))
  doAssert index.games.len == originalCount
  doAssert presented.games.len == originalCount + 1
  doAssert presented.visibleGames(0)[0].hash == GrimoireApplicationHash
  doAssert index.withApplications(LibraryConfig()).games.len == originalCount
  for theme in MenuTheme:
    let state = LibraryViewState(page: GamesPage, theme: theme, transition: 1)
    doAssert state.selectedTarget().action == PlayGame
    for dimensions in [(640, 480), (720, 480), (320, 240), (1024, 768)]:
      let layout = state.pageLayout(presented, dimensions[0], dimensions[1])
      var found = false
      for item in layout.targets:
        if item.action == SelectGame and item.index == 0:
          found = true
          let hit = layout.hitTarget(vec2((item.area.x + item.area.width div 2).float32,
            (item.area.y + item.area.height div 2).float32))
          doAssert hit.action == SelectGame and hit.index == 0
      doAssert found
    ui.renderLibrary(paths, presented, state, power, 640, 480, false, @[]).writeFile(
      "build/app-grimoire-" & ThemeKeys[theme] & ".png")

proc main() =
  ## Render every library page at handheld sizes without opening a display.
  let
    root = createTempDir("mono-retro-library-view-", "")
    paths = libraryPaths(root, root / "config.json")
    ui = newLibraryUi()
    power = PowerStatus(selected: "fixture", batteries: @[
      BatteryReading(name: "fixture", status: "Discharging", percent: 82)])
    text = newLauncherUi()
  defer: removeDir(root)
  createDir(root / "artwork")
  var index = LibraryIndex(version: 1, collections: @[
    LibraryCollection(id: 1, name: "Handheld games", selected: true)])
  for number, title in ["Lost in Blue", "Contact", "Mother 3", "Metroid Fusion", "Decompbound", "Goodboy Galaxy"]:
    let
      cover = newCanvas(160, 210)
      path = "artwork/" & $number & ".png"
    cover.fill(color(0.08, 0.16 + number.float32 * 0.05, 0.25 + number.float32 * 0.07, 1))
    cover.rect(12, 20, 136, 5, 0x72dfc3'u32)
    text.label(cover, "mono-retro", 12, 40, 18)
    text.label(cover, $number, 60, 100, 42)
    cover.writeFile(root / path)
    index.games.add LibraryGame(title: title, hash: $number, core: "fixture", platform: "nds", cover: path)
  index.games.add LibraryGame(title: "A very long translated game title with no cover or installed emulator",
    hash: "missing", platform: "gba")
  for theme in MenuTheme:
    for page in LibraryPage:
      let state = LibraryViewState(page: page, theme: theme, previewTheme: theme, transition: 1,
        message: "https://romm.example/pair/device?code=TESTCODE")
      for dimensions in [(640, 480), (720, 480), (1024, 768), (320, 240)]:
        for top in [false, true]:
          let image = ui.renderLibrary(paths, index, state, power,
            dimensions[0], dimensions[1], top, @["Fixture system info"])
          doAssert image.width == dimensions[0] and image.height == dimensions[1]
        let
          layout = state.pageLayout(index, dimensions[0], dimensions[1])
          grid = themeLayout(theme, dimensions[0], dimensions[1], 0, index.games.len)
        for card in grid.cards:
          doAssert card.y + card.height < grid.play.y
        for item in layout.targets:
          let area = item.area
          doAssert area.x >= 0 and area.y >= 0 and area.width > 0 and area.height > 0
          doAssert area.x + area.width <= dimensions[0] and area.y + area.height <= dimensions[1]
          if page == WorkbenchPage: doAssert area.y + area.height <= dimensions[1] - 64
          let hit = layout.hitTarget(vec2((area.x + area.width div 2).float32,
            (area.y + area.height div 2).float32))
          doAssert hit.action == item.action and hit.index == item.index
        doAssert layout.hitTarget(vec2(-1, -1)).action == NoViewAction
  createDir("build")
  ui.renderLibrary(paths, index, LibraryViewState(transition: 1), power,
    640, 480, false, @[]).writeFile("build/library-grid-preview.png")
  ui.renderLibrary(paths, index, LibraryViewState(transition: 1), power,
    720, 720, true, @[]).writeFile("build/library-details-preview.png")
  doAssert index.visibleGames(2).len == 0
  let preferences = root / "preferences" / "menu.json"
  doAssert loadTheme(preferences) == LibraryTheme
  for theme in MenuTheme:
    var state = LibraryViewState(theme: LibraryTheme, page: GamesPage,
      selected: 3, filter: 1, busy: true, message: "Downloading games")
    state.beginAppearance()
    state.previewTheme = theme
    state.cancelAppearance()
    doAssert state.theme == LibraryTheme and state.page == GamesPage
    doAssert not fileExists(preferences)
    state.beginAppearance()
    state.previewTheme = theme
    state.applyAppearance(preferences)
    doAssert state.theme == theme and loadTheme(preferences) == theme
    doAssert state.page == theme.homePage()
    doAssert state.selected == 3 and state.filter == 1 and state.busy
    doAssert state.message == "Downloading games"
    removeFile(preferences)
  var showcase = LibraryViewState(theme: ShowcaseTheme)
  showcase.moveSelection(index, 1024, 768, 1, true)
  doAssert showcase.selected == 1
  var library = LibraryViewState(theme: LibraryTheme)
  library.moveSelection(index, 1024, 768, 1, true)
  doAssert library.selected == 5
  var workbench = LibraryViewState(theme: WorkbenchTheme, page: WorkbenchPage)
  doAssert workbench.selectedTarget().action == TestHardware
  workbench.moveSelection(index, 1024, 768, 1, true)
  doAssert workbench.selectedTarget().action == ShowGames
  let gallery = newCanvas(1280, 1024)
  gallery.fill(0x030609'u32)
  for theme in MenuTheme:
    for empty in [false, true]:
      let model = if empty: LibraryIndex() else: index
      discard ui.renderLibrary(paths, model,
        LibraryViewState(theme: theme, selected: model.games.high, transition: 1),
        power, 640, 480, false, @[])
    let
      state = LibraryViewState(theme: theme, page: theme.homePage(), transition: 1, message: "Ready")
      top = ui.renderLibrary(paths, index, state, power, 640, 480, true,
        @["Gentoo Linux", "Kernel: 7.0.2", "Wi-Fi connected", "Battery: 82%"])
      bottom = ui.renderLibrary(paths, index, state, power, 640, 480, false, @[])
      pair = newCanvas(640, 968)
    pair.fill(0x030609'u32)
    pair.draw(top)
    pair.draw(bottom, translate(vec2(0, 488)))
    pair.writeFile("build/theme-" & ThemeKeys[theme] & "-dual.png")
    bottom.writeFile("build/theme-" & ThemeKeys[theme] & "-single.png")
    let
      x = ord(theme) mod 2 * 640
      y = ord(theme) div 2 * 512
    text.label(gallery, ThemeNames[theme], x + 16, y + 6, 18)
    gallery.draw(bottom, translate(vec2(x.float32, (y + 32).float32)))
  gallery.writeFile("build/theme-gallery.png")
  testWifiPages(ui, paths, index, power)
  testGrimoireApp(ui, paths, index, power)

main()
