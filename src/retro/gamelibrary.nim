import
  std/[algorithm, json, jsonutils, os, osproc, posix, sequtils, sha1, strutils, times],
  ./playersave

type
  CoreConfig* = object
    key*, path*: string
    platforms*, arguments*: seq[string]
    romHash*: string
  LibraryConfig* = object
    expectedUuid*, rommUrl*, playerPath*: string
    cores*: seq[CoreConfig]
  LibraryGame* = ref object
    hash*, path*, title*, platform*, core*, cover*, coverSource*, summary*: string
    rommId*: int
    rommOrigin*: string
    size*, modified*, lastPlayed*: int64
    favourite*: bool
    saveConflict*: bool
  LibraryCollection* = object
    id*: int
    name*: string
    selected*: bool
  LibraryIndex* = object
    version*: int
    games*: seq[LibraryGame]
    collections*: seq[LibraryCollection]
  LibraryPaths* = object
    root*, data*, index*, config*, credentials*: string
  LibraryLock* = object
    file: File

const
  LibraryVersion* = 1
  HashBufferBytes = 64 * 1024

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

proc stringField*(node: JsonNode, key: string, default = ""): string =
  ## Read optional API and progress text without treating null as a string.
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr() else: default

proc intField*(node: JsonNode, key: string, default = 0): int =
  ## Read optional integer fields while retaining explicit defaults.
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    node[key].getInt() else: default

proc libraryPaths*(root, config: string): LibraryPaths =
  ## Resolve portable data separately from machine configuration and credentials.
  result.root = absolutePath(root)
  result.data = result.root / "mono-retro"
  result.index = result.data / "library" / "index.json"
  result.config = absolutePath(config)
  result.credentials = result.config.parentDir / "private" / "romm-credentials.json"

proc loadConfig*(path: string): LibraryConfig =
  ## Read explicit machine-local core associations without loading other secrets.
  if not fileExists(path): raise newException(IOError, "Library configuration not found: " & path)
  result = parseFile(path).jsonTo(LibraryConfig, Joptions(allowMissingKeys: true))
  if result.playerPath.len == 0:
    raise newException(ValueError, "Library configuration requires playerPath")
  if result.rommUrl.len > 0 and not result.rommUrl.startsWith("https://"):
    when not defined(libraryTesting):
      raise newException(ValueError, "RomM requires HTTPS")

proc requireStorage*(paths: LibraryPaths, config: LibraryConfig) =
  ## Reject missing volumes before any operation can create OS-card save paths.
  if not dirExists(paths.root): raise newException(IOError, "Games card is missing")
  if config.expectedUuid.len > 0:
    let mounted = execCmdEx("findmnt -rn -M " & quoteShell(paths.root) & " -o UUID")
    if mounted.exitCode != 0 or mounted.output.strip() != config.expectedUuid:
      raise newException(IOError, "The expected games card is not mounted")
  if access(paths.root.cstring, W_OK) != 0:
    raise newException(IOError, "Games card is read-only")

proc inside*(root, relative: string): string =
  ## Restrict persisted and server-provided paths to the configured library.
  if relative.len == 0 or relative.isAbsolute or '\\' in relative:
    raise newException(ValueError, "Invalid library-relative path")
  for part in relative.split('/'):
    if part in ["", ".", ".."]: raise newException(ValueError, "Invalid library-relative path")
  result = root / relative
  var parent = result
  while parent != root:
    if symlinkExists(parent): raise newException(ValueError, "Library paths cannot traverse symbolic links")
    parent = parent.parentDir

proc prepareStorage*(paths: LibraryPaths, config: LibraryConfig) =
  ## Create only app-owned data folders after validating the mounted volume.
  paths.requireStorage(config)
  for folder in ["saves", "artwork", "library", "settings", "screenshots"]:
    createDir(paths.root.inside("mono-retro/" & folder))

proc lockLibrary*(paths: LibraryPaths, config: LibraryConfig): LibraryLock =
  ## Serialize scanner, preference and synchronization writers across processes.
  paths.prepareStorage(config)
  result.file = open(paths.data / "library" / ".lock", fmAppend)
  if flock(result.file.getFileHandle(), 2 or 4) != 0:
    result.file.close()
    raise newException(IOError, "The library is busy")
  if fcntl(result.file.getFileHandle(), F_SETFD, FD_CLOEXEC) < 0:
    result.file.close()
    raiseOSError(osLastError())

proc close*(lock: var LibraryLock) =
  ## Release the process lock without deleting its stable inode.
  if lock.file != nil:
    lock.file.close()
    lock.file = nil

proc loadIndex*(paths: LibraryPaths): LibraryIndex =
  ## Read the last complete portable library snapshot.
  result.version = LibraryVersion
  if fileExists(paths.index):
    result = parseFile(paths.index).jsonTo(LibraryIndex, Joptions(allowMissingKeys: true))
    if result.version != LibraryVersion:
      raise newException(ValueError, "Unsupported library index version")

proc saveIndex*(paths: LibraryPaths, index: LibraryIndex) =
  ## Publish a complete library snapshot through the player's durable writer.
  writeSave(paths.index, $index.toJson())

proc fileHash*(path: string): string =
  ## Compute a streaming ROM identity without buffering large images in memory.
  var
    state = newSha1State()
    buffer = newString(HashBufferBytes)
  let file = open(path, fmRead)
  defer: file.close()
  while true:
    let count = file.readBuffer(addr buffer[0], buffer.len)
    if count == 0: break
    state.update(buffer.toOpenArray(0, count - 1))
  ($SecureHash(state.finalize())).toUpperAscii()

proc platformFor*(path: string): string =
  ## Recognize the loose cartridge formats supported by the library player.
  case path.splitFile.ext.toLowerAscii()
  of ".nds": "nds"
  of ".gba": "gba"
  of ".gb": "gb"
  of ".gbc": "gbc"
  of ".nes": "nes"
  of ".smc", ".sfc": "snes"
  else: ""

proc coreFor*(config: LibraryConfig, game: LibraryGame): string =
  ## Prefer exact-ROM associations before general system associations.
  for core in config.cores:
    if core.romHash.len > 0 and cmpIgnoreCase(core.romHash, game.hash) == 0:
      return core.key
  for core in config.cores:
    if core.romHash.len == 0 and game.platform in core.platforms: return core.key

proc preserveRenamedSave(paths: LibraryPaths, game: LibraryGame, path, core: string) =
  ## Keep the player's stem-based cartridge save attached to a renamed ROM.
  if game.path == path or game.core.len == 0 or game.core != core: return
  let
    base = "mono-retro/saves/" & game.core & "/" & game.hash
    previous = paths.root.inside(base & "/" & game.path.splitFile.name & ".srm")
    current = paths.root.inside(base & "/" & path.splitFile.name & ".srm")
  if previous == current or not fileExists(previous): return
  if fileExists(current):
    if getFileInfo(previous).id == getFileInfo(current).id: return
    if readFile(previous) != readFile(current):
      raise newException(IOError, "Two different saves exist for a renamed ROM; resolve them before rescanning")
  discard writeNewSave(previous & ".before-rom-rename", readFile(previous))
  if fileExists(current): removeFile(previous)
  else: moveFile(previous, current)

proc scanLibrary*(paths: LibraryPaths, config: LibraryConfig): LibraryIndex =
  ## Discover local games while retaining identities, metadata and play history.
  paths.requireStorage(config)
  result = paths.loadIndex()
  let roms = paths.root / "Roms"
  if not dirExists(roms): return
  var found: seq[string]
  var files: seq[string]
  for path in walkDirRec(roms, yieldFilter = {pcFile}): files.add path
  files.sort()
  for path in files:
    let
      relative = relativePath(path, paths.root)
      platform = platformFor(path)
    if platform.len == 0: continue
    discard paths.root.inside(relative)
    let info = getFileInfo(path)
    var game: LibraryGame
    for previous in result.games:
      if previous.path == relative: game = previous; break
    let hash = if game != nil and game.size == info.size and
        game.modified == info.lastWriteTime.toUnix: game.hash else: fileHash(path)
    if game == nil or game.hash != hash:
      game = nil
      for previous in result.games:
        if previous.hash == hash: game = previous; break
      if game == nil:
        game = LibraryGame(hash: hash, title: path.splitFile.name, platform: platform)
        result.games.add game
    if hash in found: continue
    found.add hash
    let core = config.coreFor(game)
    paths.preserveRenamedSave(game, relative, core)
    game.path = relative
    game.size = info.size
    game.modified = info.lastWriteTime.toUnix
    game.core = core
  result.games = result.games.filterIt(it.hash in found)
  result.games.sort(proc(a, b: LibraryGame): int = cmpIgnoreCase(a.title, b.title))

proc gameSaveDir*(paths: LibraryPaths, game: LibraryGame): string =
  ## Keep independent cartridge formats and same-named ROM revisions separate.
  if game.core.len == 0: raise newException(ValueError, "No core configured for this game")
  paths.root.inside("mono-retro/saves/" & game.core & "/" & game.hash)

proc gameArguments*(paths: LibraryPaths, config: LibraryConfig,
    game: LibraryGame): seq[string] =
  ## Resolve and validate one launch without creating or modifying a save.
  paths.requireStorage(config)
  let rom = paths.root.inside(game.path)
  if not fileExists(rom) or fileHash(rom) != game.hash:
    raise newException(IOError, "Game file changed; rescan the library")
  for core in config.cores:
    if core.key == game.core:
      if not fileExists(core.path): raise newException(IOError, "Emulator core is not installed: " & core.key)
      return @["--core:" & core.path, "--rom:" & rom,
        "--save-dir:" & paths.gameSaveDir(game),
        "--screenstate-dir:" & paths.data / "screenshots"] & core.arguments
  raise newException(ValueError, "No emulator configured for " & game.title)
