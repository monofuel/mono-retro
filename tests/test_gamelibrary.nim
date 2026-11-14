import
  std/[json, jsonutils, os, tempfiles],
  retro/[gamelibrary, libraryview]

proc expectFailure(action: proc()) =
  ## Require a storage or launch error rather than permitting a silent fallback.
  var raised = false
  try: action()
  except IOError, OSError, ValueError: raised = true
  doAssert raised

proc main() =
  ## Exercise portable discovery, core selection and missing-card safeguards.
  let
    temporary = createTempDir("mono-retro-library-test-", "")
    root = temporary / "card"
    configPath = temporary / "config" / "library.json"
    rom = root / "Roms" / "NDS" / "Game.nds"
    second = root / "Roms" / "NDS" / "Other.nds"
    corePath = temporary / "core.so"
    paths = libraryPaths(root, configPath)
  defer: removeDir(temporary)
  createDir(rom.parentDir)
  createDir(configPath.parentDir)
  writeFile(rom, "original game")
  writeFile(second, "different game")
  writeFile(corePath, "fixture")
  let config = LibraryConfig(playerPath: "/player", cores: @[
    CoreConfig(key: "ds", path: corePath, platforms: @["nds"], arguments: @["--ds-layout:separate"])])
  writeFile(configPath, $config.toJson())
  doAssert loadConfig(configPath).cores.len == 1
  paths.prepareStorage(config)
  var index = paths.scanLibrary(config)
  doAssert index.games.len == 2
  doAssert index.games[0].title == "Game"
  let game = index.games[0]
  doAssert game.hash == fileHash(rom)
  doAssert game.path == "Roms/NDS/Game.nds"
  game.favourite = true
  game.lastPlayed = 50
  paths.saveIndex(index)
  let again = paths.scanLibrary(config)
  doAssert again.games[0].favourite
  doAssert again.visibleGames(1).len == 1
  doAssert again.visibleGames(2).len == 1
  doAssert again.filters() == @["All", "Recent", "Favourites", "NDS"]
  let arguments = paths.gameArguments(config, game)
  doAssert "--save-dir:" & root / "mono-retro/saves/ds" / game.hash in arguments
  doAssert "--screenstate-dir:" & root / "mono-retro/screenshots" in arguments
  doAssert not dirExists(paths.gameSaveDir(game))
  createDir(paths.gameSaveDir(game))
  writeFile(paths.gameSaveDir(game) / "Game.srm", "cartridge progress")
  expectFailure(proc() = discard root.inside("../outside"))
  expectFailure(proc() = discard root.inside("Roms/../../outside"))
  createSymlink(temporary, root / "escape")
  expectFailure(proc() = discard root.inside("escape/secret"))
  block:
    var lock = paths.lockLibrary(config)
    defer: lock.close()
    expectFailure(proc() =
      var other = paths.lockLibrary(config)
      other.close())
  var missing = config
  missing.expectedUuid = "not-a-mounted-card"
  expectFailure(proc() = paths.prepareStorage(missing))
  let missingPaths = libraryPaths(temporary / "absent", configPath)
  expectFailure(proc() = missingPaths.prepareStorage(config))
  doAssert not dirExists(missingPaths.root)
  moveFile(rom, rom.parentDir / "Renamed.nds")
  index = paths.scanLibrary(config)
  doAssert index.games.len == 2
  doAssert index.games[0].hash == game.hash
  doAssert index.games[0].favourite
  doAssert index.games[0].path == "Roms/NDS/Renamed.nds"
  doAssert readFile(paths.gameSaveDir(game) / "Renamed.srm") == "cartridge progress"
  doAssert readFile(paths.gameSaveDir(game) / "Game.srm.before-rom-rename") == "cartridge progress"
  writeFile(rom.parentDir / "Renamed.nds", "changed game content")
  expectFailure(proc() = discard paths.gameArguments(config, game))
  index = paths.scanLibrary(config)
  doAssert index.games.len == 2
  for item in index.games:
    if item.path == "Roms/NDS/Renamed.nds": doAssert item.hash != game.hash
  let layout = libraryLayout(640, 480, 6, 8)
  doAssert layout.columns == 3
  doAssert layout.first == 6
  doAssert layout.cards.len == 2
  for area in layout.cards:
    doAssert area.x >= 0 and area.y >= 0
    doAssert area.x + area.width <= 640
    doAssert area.y + area.height < layout.play.y
  let nes = root / "Roms" / "Fixture.nes"
  writeFile(nes, "synthetic NES cartridge")
  index = paths.scanLibrary(config)
  doAssert index.games.len == 3
  for item in index.games:
    if item.path == "Roms/Fixture.nes":
      doAssert item.platform == "nes" and item.core.len == 0

main()
