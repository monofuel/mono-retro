import
  std/[json, os, parseopt, strutils, times],
  retro/[gamelibrary, playersave, rommclient]

const
  Help = """Usage: mono-retro-library COMMAND --library:DIR --config:FILE [options]
Commands: scan, sync, sync-saves, pair, status, collections, select, favourite,
          played, resolve, disconnect.
Options: --game:SHA1 --id:N --choice:local|server --name:NAME --progress:FILE.
Pair prints a browser URL and approval code, never an account password or token.
"""

proc runLibraryCommand*(command, root, configPath, gameHash: string,
    collectionId: int, name, choice: string, progress: LibraryProgress): JsonNode =
  ## Share library operations between the CLI and the launcher's worker process.
  let
    paths = libraryPaths(root, configPath)
    config = loadConfig(paths.config)
  if command == "disconnect":
    if fileExists(paths.credentials): removeFile(paths.credentials)
    return %*{"message": "Disconnected from RomM"}
  if command == "pair":
    let client = newRommClient(config.rommUrl)
    defer: client.close()
    let
      identity = paths.config.parentDir / "private" / "device-id"
      identifier = if fileExists(identity): readFile(identity).strip()
        else: "mono-retro-" & $getTime().toUnix & "-" & $getCurrentProcessId()
      flow = client.beginPairing(identifier, name)
      interval = max(1, flow.intField("interval", 5))
      expires = epochTime() + flow.intField("expires_in", 300).float64
      verification = flow.stringField("verification_path")
    if not verification.startsWith("/") or verification.startsWith("//"):
      raise newException(ValueError, "Invalid RomM approval URL")
    progress("Open " & config.rommUrl & verification & "\nCode: " & flow.stringField("user_code"))
    while epochTime() < expires:
      sleep(interval * 1000)
      if client.pollPairing(flow.stringField("device_code"), paths.credentials):
        writeSave(identity, identifier)
        setFilePermissions(identity, {fpUserRead, fpUserWrite})
        return %*{"message": "Connected to RomM"}
    raise newException(IOError, "Pairing expired; choose Connect again")
  paths.requireStorage(config)
  if command == "status":
    let index = paths.loadIndex()
    return %*{"message": "Library available", "games": index.games.len,
      "paired": fileExists(paths.credentials)}
  var
    lock = paths.lockLibrary(config)
    index = paths.loadIndex()
  defer: lock.close()
  case command
  of "scan":
    progress("Scanning games card")
    index = paths.scanLibrary(config)
    paths.saveIndex(index)
  of "favourite", "played":
    var found = false
    for game in index.games:
      if game.hash == gameHash:
        found = true
        if command == "favourite": game.favourite = not game.favourite
        else: game.lastPlayed = getTime().toUnix
    if not found: raise newException(ValueError, "Game not found; rescan the library")
    paths.saveIndex(index)
  of "select":
    var found = false
    for collection in index.collections.mitems:
      if collection.id == collectionId:
        collection.selected = not collection.selected
        found = true
    if not found: raise newException(ValueError, "Collection not found; sync RomM first")
    paths.saveIndex(index)
  of "sync", "sync-saves", "collections", "resolve":
    let client = newRommClient(config.rommUrl,
      loadCredentials(paths.credentials, apiOrigin(config.rommUrl)))
    defer: client.close()
    if command == "resolve":
      client.resolveSave(paths, config, index, gameHash, choice)
    elif command == "collections":
      client.refreshCollections(paths, index)
    elif command == "sync":
      index = paths.scanLibrary(config)
      paths.saveIndex(index)
      client.syncCatalogue(paths, config, index, progress)
    if command notin ["collections", "resolve"]:
      client.syncSaves(paths, config, index, progress, gameHash)
  else: raise newException(ValueError, Help)
  %*{"message": "Ready", "games": index.games.len}

proc main() =
  ## Run one operation, publishing nonsecret progress for an optional GUI owner.
  if paramCount() == 0: stdout.write(Help); return
  var
    root = "/media/games"
    configPath = getHomeDir() / ".config" / "mono-retro" / "library.json"
    gameHash, progressPath, choice: string
    name = "mono-retro handheld"
    collectionId = 0
    arguments: seq[string]
  for index in 2 .. paramCount(): arguments.add paramStr(index)
  var parser = initOptParser(arguments)
  for kind, key, value in parser.getopt():
    if kind != cmdLongOption: raise newException(ValueError, Help)
    case key
    of "library": root = value
    of "config": configPath = value
    of "game": gameHash = value
    of "id": collectionId = parseInt(value)
    of "choice": choice = value
    of "name": name = value
    of "progress": progressPath = value
    else: raise newException(ValueError, Help)
  proc report(message: string) =
    ## Share status without passing private device codes or tokens to the UI.
    let node = %*{"message": message, "running": true}
    if progressPath.len > 0: writeSave(progressPath, $node)
    else:
      stdout.writeLine($node)
      stdout.flushFile()
  try:
    var result = runLibraryCommand(paramStr(1), root, configPath, gameHash,
      collectionId, name, choice, report)
    result["running"] = %false
    if progressPath.len > 0: writeSave(progressPath, $result)
    stdout.writeLine($result)
  except CatchableError as error:
    let node = %*{"message": error.msg, "running": false, "error": true}
    if progressPath.len > 0: writeSave(progressPath, $node)
    stderr.writeLine($node)
    quit(1)

when isMainModule:
  main()
