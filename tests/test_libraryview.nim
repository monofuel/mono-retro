import
  std/[os, tempfiles],
  pixie,
  retro/[gamelibrary, launcherui, libraryview, pattern, systeminfo]

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
  for page in LibraryPage:
    let state = LibraryViewState(page: page, transition: 1,
      message: "Open https://romm.example/pair/device\nCode: TESTCODE")
    for dimensions in [(640, 480), (720, 720), (320, 240)]:
      let image = ui.renderLibrary(paths, index, state, power,
        dimensions[0], dimensions[1], false, @["Fixture system info"])
      doAssert image.width == dimensions[0] and image.height == dimensions[1]
      let layout = libraryLayout(dimensions[0], dimensions[1], 0, index.games.len)
      for card in layout.cards:
        doAssert card.y + card.height < layout.play.y
  createDir("build")
  ui.renderLibrary(paths, index, LibraryViewState(transition: 1), power,
    640, 480, false, @[]).writeFile("build/library-grid-preview.png")
  ui.renderLibrary(paths, index, LibraryViewState(transition: 1), power,
    720, 720, true, @[]).writeFile("build/library-details-preview.png")
  doAssert index.visibleGames(2).len == 0

main()
