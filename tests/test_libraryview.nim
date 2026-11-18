import
  std/[os, tempfiles],
  pixie,
  retro/[gamelibrary, launcherui, libraryview, menuthemes, pattern, systeminfo]

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

main()
