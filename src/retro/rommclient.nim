import
  std/[json, md5, os, posix, strutils, tempfiles, times, uri],
  curly,
  ./[gamelibrary, playersave]

type
  RommCredentials* = object
    origin*, token*, deviceId*: string
  RommClient* = ref object
    curl: Curly
    credentials: RommCredentials
  LibraryProgress* = proc(message: string) {.closure.}

const
  RequestTimeout = 15
  DownloadTimeout = 60
  ReserveBytes = 32'i64 * 1024 * 1024
  MaximumSaveBytes = 16 * 1024 * 1024
  MaximumRomBytes = 512'i64 * 1024 * 1024
  PrivatePermissions = {fpUserRead, fpUserWrite}
  RequestedScopes = ["roms.read", "platforms.read", "collections.read",
    "devices.read", "devices.write", "assets.read", "assets.write"]

proc apiJson(body: string): JsonNode =
  ## Do not include potentially credential-bearing response bytes in parse errors.
  try: result = parseJson(body)
  except JsonParsingError:
    raise newException(IOError, "RomM returned invalid JSON")

proc apiOrigin*(url: string): string =
  ## Require a configured HTTPS origin, with no embedded login or redirect base.
  let parsed = parseUri(url)
  if parsed.hostname.len == 0 or parsed.username.len > 0 or parsed.password.len > 0 or
      parsed.query.len > 0 or parsed.anchor.len > 0 or parsed.path notin ["", "/"]:
    raise newException(ValueError, "RomM URL must be an origin without credentials")
  if parsed.scheme != "https":
    when defined(libraryTesting):
      if parsed.scheme != "http" or parsed.hostname notin ["127.0.0.1", "localhost"]:
        raise newException(ValueError, "Test HTTP requires loopback")
    else:
      raise newException(ValueError, "RomM requires HTTPS")
  url.strip(leading = false, chars = {'/'})

proc loadCredentials*(path: string, origin: string): RommCredentials =
  ## Keep device tokens in owner-only OS storage and bind them to their origin.
  if not fileExists(path): raise newException(IOError, "Connect to RomM in Settings first")
  if getFilePermissions(path) - PrivatePermissions != {}:
    raise newException(ValueError, "RomM credentials must be owner-only")
  if getFileSize(path) notin 1'i64 .. 16384'i64:
    raise newException(ValueError, "Invalid RomM credential file")
  var node: JsonNode
  try: node = parseFile(path)
  except CatchableError:
    raise newException(ValueError, "Cannot parse RomM credentials; reconnect")
  result = RommCredentials(origin: node.stringField("origin"),
    token: node.stringField("token"), deviceId: node.stringField("deviceId"))
  if result.origin != origin or result.token.len == 0 or result.deviceId.len == 0:
    raise newException(ValueError, "RomM authorization does not match this server; reconnect")

proc saveCredentials*(path: string, credentials: RommCredentials) =
  ## Publish a token privately without exposing it in diagnostics or arguments.
  createDir(path.parentDir)
  setFilePermissions(path.parentDir, {fpUserRead, fpUserWrite, fpUserExec})
  let (file, temporary) = createTempFile(".romm-", ".json", path.parentDir)
  try:
    try:
      setFilePermissions(temporary, PrivatePermissions)
      file.write($(%*{"origin": credentials.origin, "token": credentials.token,
        "deviceId": credentials.deviceId}))
      file.flushSaveFile()
    finally: file.close()
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc newRommClient*(origin: string, credentials: RommCredentials = RommCredentials()): RommClient =
  ## Reuse one Curly transport throughout a pairing or synchronization job.
  result = RommClient(curl: newCurly(maxInFlight = 1), credentials: credentials)
  result.credentials.origin = apiOrigin(origin)

proc close*(client: RommClient) =
  ## Drain and close transport ownership at the job boundary.
  client.curl.close()

proc headers(client: RommClient): HttpHeaders =
  ## Attach a token to requests to the configured server only.
  result = @[ ("Accept", "application/json"), ("User-Agent", "mono-retro/0.1") ]
  if client.credentials.token.len > 0:
    result.add ("Authorization", "Bearer " & client.credentials.token)

proc request*(client: RommClient, verb, path: string, body = ""): Response =
  ## Keep credentials out of transport failures and reject redirected API replies.
  if not path.startsWith("/api/"):
    raise newException(ValueError, "Invalid RomM API path")
  var fields = client.headers()
  if body.len > 0: fields.add ("Content-Type", "application/json")
  try:
    result = client.curl.makeRequest(verb, client.credentials.origin & path,
      fields, body, timeout = RequestTimeout)
  except CatchableError:
    raise newException(IOError, "Cannot reach RomM; local games remain available")
  if not result.url.startsWith(client.credentials.origin & "/api/"):
    raise newException(IOError, "RomM redirected an API request")

proc jsonRequest*(client: RommClient, verb, path: string, body = ""): JsonNode =
  ## Interpret only successful API replies; never print response bodies or tokens.
  let response = client.request(verb, path, body)
  if response.code notin 200 .. 299:
    if response.code == 401: raise newException(IOError, "RomM authorization expired or was revoked; reconnect")
    if response.code == 403: raise newException(IOError, "RomM authorization lacks required permissions")
    raise newException(IOError, "RomM request failed (HTTP " & $response.code & ")")
  apiJson(response.body)

proc beginPairing*(client: RommClient, identifier, name: string): JsonNode =
  ## Start browser approval without receiving or storing an account password.
  client.jsonRequest("POST", "/api/auth/device/init", $(%*{
    "client_device_identifier": identifier, "name": name,
    "client": "mono-retro", "platform": "linux", "client_version": "0.1.0",
    "requested_scopes": RequestedScopes}))

proc pollPairing*(client: RommClient, code, credentialPath: string): bool =
  ## Return pending approval, or privately publish the approved device token.
  let response = client.request("POST", "/api/auth/device/token", $(%*{"device_code": code}))
  let node = apiJson(response.body)
  if response.code == 200 and node.stringField("access_token").len > 0:
    saveCredentials(credentialPath, RommCredentials(origin: client.credentials.origin,
      token: node.stringField("access_token"), deviceId: node.stringField("device_id")))
    return true
  let error = node.stringField("error", node.stringField("detail"))
  if response.code in [202, 428] or error in ["authorization_pending", "slow_down"]:
    return false
  raise newException(IOError, "RomM pairing expired or was declined; start Connect again")

proc freeBytes(path: string): int64 =
  ## Read available card capacity before starting a streamed download.
  var info: Statvfs
  if statvfs(path.cstring, info) != 0: raiseOSError(osLastError())
  int64(info.f_bavail) * int64(info.f_frsize)

proc download*(client: RommClient, path, destination: string,
    expectedBytes: int64, expectedSha1 = "") =
  ## Publish a complete download after checking capacity, size and content identity.
  if not path.startsWith("/") or path.startsWith("//") or
      expectedBytes < 0 or expectedBytes > MaximumRomBytes:
    raise newException(ValueError, "Invalid RomM download")
  if freeBytes(destination.parentDir) < expectedBytes + ReserveBytes:
    raise newException(IOError, "Not enough space on the games card")
  let (file, temporary) = createTempFile(".romm-download-", ".part", destination.parentDir)
  try:
    try:
      let stream = client.curl.request("GET", client.credentials.origin & path.replace(" ", "%20"),
        client.headers(), timeout = DownloadTimeout)
      defer: stream.close()
      if stream.code != 200 or not stream.url.startsWith(client.credentials.origin & "/"):
        raise newException(IOError, "RomM download failed (HTTP " & $stream.code & ")")
      var
        buffer: string
        received = 0'i64
      while stream.read(buffer) > 0:
        received += buffer.len
        if (expectedBytes > 0 and received > expectedBytes) or
            (expectedBytes == 0 and received > MaximumSaveBytes):
          raise newException(IOError, "RomM download exceeded its expected size")
        file.write(buffer)
        buffer.setLen(0)
      if expectedBytes > 0 and received != expectedBytes:
        raise newException(IOError, "RomM download is incomplete")
      file.flushSaveFile()
    finally: file.close()
    if expectedSha1.len > 0 and cmpIgnoreCase(fileHash(temporary), expectedSha1) != 0:
      raise newException(IOError, "Downloaded ROM hash does not match RomM")
    moveFile(temporary, destination)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc updateMetadata(client: RommClient, paths: LibraryPaths, game: LibraryGame,
    node: JsonNode) =
  ## Associate by content hash and cache server artwork separately from the ROM.
  if cmpIgnoreCase(node.stringField("sha1_hash"), game.hash) != 0:
    game.rommId = 0
    game.rommOrigin = ""
    return
  game.rommId = node.intField("id")
  game.rommOrigin = client.credentials.origin
  game.title = node.stringField("name", game.title)
  game.summary = node.stringField("summary")
  let art = node.stringField("path_cover_small")
  if art.len > 0:
    let
      path = if art.startsWith("/"): art else: "/assets/" & art
      destination = paths.data / "artwork" / (game.hash & ".image")
    if not fileExists(destination) or game.coverSource != art:
      client.download(path, destination, 0)
    game.cover = relativePath(destination, paths.root)
    game.coverSource = art

proc refreshCollections*(client: RommClient, paths: LibraryPaths, index: var LibraryIndex) =
  ## Refresh the chooser without starting downloads that could block deselection.
  let collections = client.jsonRequest("GET", "/api/collections")
  var updated: seq[LibraryCollection]
  for node in collections:
    var collection = LibraryCollection(id: node.intField("id"), name: node.stringField("name"))
    for old in index.collections:
      if old.id == collection.id: collection.selected = old.selected
    updated.add collection
  index.collections = updated
  paths.saveIndex(index)

proc syncCatalogue*(client: RommClient, paths: LibraryPaths,
    config: LibraryConfig, index: var LibraryIndex, progress: LibraryProgress) =
  ## Refresh selected collections, adopting matching games before downloading.
  client.refreshCollections(paths, index)
  for game in index.games:
    let endpoint = if game.rommId != 0 and game.rommOrigin == client.credentials.origin:
      "/api/roms/" & $game.rommId & "/simple" else: "/api/roms/by-hash?sha1_hash=" & game.hash
    let response = client.request("GET", endpoint)
    if response.code == 404:
      game.rommId = 0
      game.rommOrigin = ""
      continue
    if response.code != 200:
      raise newException(IOError, "RomM game lookup failed (HTTP " & $response.code & ")")
    let matches = apiJson(response.body)
    if matches.kind == JObject and matches.hasKey("id"):
      client.updateMetadata(paths, game, matches)
    elif matches.kind == JArray and matches.len == 1:
      client.updateMetadata(paths, game, matches[0])
    paths.saveIndex(index)
  for collection in index.collections:
    if not collection.selected: continue
    var offset = 0
    while true:
      let page = client.jsonRequest("GET", "/api/roms?collection_id=" & $collection.id &
        "&limit=50&offset=" & $offset & "&with_rom_id_index=false&with_filter_values=false&with_char_index=false")
      let items = page["items"]
      for node in items:
        let
          hash = node.stringField("sha1_hash").toUpperAscii()
          filename = node.stringField("fs_name")
          platform = platformFor(filename)
        if hash.len != 40 or platform.len == 0 or filename.extractFilename != filename: continue
        var game: LibraryGame
        for local in index.games:
          if local.hash == hash: game = local; break
        if game == nil:
          game = LibraryGame(hash: hash, title: node.stringField("name", filename), platform: platform)
          game.core = config.coreFor(game)
          if game.core.len == 0: continue
          let folder = paths.root.inside("Roms/" & platform.toUpperAscii())
          createDir(folder)
          var destination = folder / filename
          if fileExists(destination):
            let split = filename.splitFile
            destination = folder / (split.name & " [" & hash[0 .. 7] & "]" & split.ext)
            if fileExists(destination):
              if fileHash(destination) != hash: raise newException(IOError, "ROM download filename conflict")
          if not fileExists(destination):
            progress("Downloading " & game.title)
            client.download("/api/roms/" & $node.intField("id") & "/content/" & encodeUrl(filename, usePlus = false),
              destination, node.intField("fs_size_bytes").int64, hash)
          game.path = relativePath(destination, paths.root)
          let info = getFileInfo(destination)
          game.size = info.size
          game.modified = info.lastWriteTime.toUnix
          index.games.add game
        client.updateMetadata(paths, game, node)
        paths.saveIndex(index)
      if items.len < 50: break
      offset += items.len

proc savePath(paths: LibraryPaths, game: LibraryGame): string =
  ## Match the existing player's cartridge-save filename inside its private tree.
  paths.gameSaveDir(game) / (game.path.splitFile.name & ".srm")

proc uploadSave(client: RommClient, game: LibraryGame, path: string, session: int) =
  ## Upload a bounded raw save using RomM's guarded autosave-version operation.
  if getFileSize(path) notin 1'i64 .. MaximumSaveBytes.int64:
    raise newException(IOError, "Cartridge save has an invalid size")
  let content = readFile(path)
  let
    boundary = "MonoRetroSave" & getMD5(content)
    body = "--" & boundary & "\r\nContent-Disposition: form-data; name=\"saveFile\"; filename=\"" &
      game.hash & ".srm\"\r\nContent-Type: application/octet-stream\r\n\r\n" & content & "\r\n--" & boundary & "--\r\n"
    path = "/api/saves?rom_id=" & $game.rommId & "&slot=autosave&device_id=" &
      encodeUrl(client.credentials.deviceId) & "&session_id=" & $session &
      "&content_hash=" & getMD5(content) & "&overwrite=false&autocleanup=false"
  var fields = client.headers()
  fields.add ("Content-Type", "multipart/form-data; boundary=" & boundary)
  let response = client.curl.makeRequest("POST", client.credentials.origin & path,
    fields, body, timeout = RequestTimeout)
  if response.code notin 200 .. 299:
    raise newException(IOError, "Save upload was not accepted; local progress is preserved (HTTP " & $response.code & ")")

proc receiveSave(client: RommClient, paths: LibraryPaths, game: LibraryGame,
    operation: JsonNode, session: int): string =
  ## Verify raw save bytes before recording a successful device download baseline.
  let
    saveId = operation.intField("save_id")
    source = "/api/saves/" & $saveId & "/content?device_id=" &
      encodeUrl(client.credentials.deviceId) & "&session_id=" & $session & "&optimistic=false"
    name = operation.stringField("file_name")
    incoming = paths.savePath(game) & ".incoming"
  if name.splitFile.ext.toLowerAscii() notin [".sav", ".srm"]:
    raise newException(IOError, "Save format needs manual conversion: " & game.title)
  createDir(incoming.parentDir)
  try:
    client.download(source, incoming, 0)
    result = readFile(incoming)
    let expected = operation.stringField("server_content_hash")
    if result.len == 0 or (expected.len > 0 and cmpIgnoreCase(expected, getMD5(result)) != 0):
      raise newException(IOError, "Downloaded save failed its checksum")
  finally:
    if fileExists(incoming): removeFile(incoming)

proc acknowledgeSave(client: RommClient, operation: JsonNode, content: string) =
  ## Record only bytes already published durably on local storage.
  discard client.jsonRequest("POST", "/api/saves/" & $operation.intField("save_id") & "/downloaded",
    $(%*{"device_id": client.credentials.deviceId, "content_hash": getMD5(content)}))

proc syncSaves*(client: RommClient, paths: LibraryPaths, config: LibraryConfig,
    index: LibraryIndex, progress: LibraryProgress, onlyGame = "") =
  ## Negotiate raw saves without replacing conflicts or applying remote deletions.
  paths.requireStorage(config)
  var
    saves = newJArray()
    ids = newJArray()
  for game in index.games:
    if game.rommId == 0 or game.rommOrigin != client.credentials.origin or
        game.core.len == 0 or (onlyGame.len > 0 and game.hash != onlyGame): continue
    ids.add %game.rommId
    let path = paths.savePath(game)
    if fileExists(path):
      if getFileSize(path) notin 1'i64 .. MaximumSaveBytes.int64:
        raise newException(IOError, "Cartridge save has an invalid size: " & game.title)
      saves.add %*{"rom_id": game.rommId, "file_name": game.hash & ".srm", "slot": "autosave",
        "content_hash": getMD5(readFile(path)), "file_size_bytes": getFileSize(path),
        "updated_at": getLastModificationTime(path).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")}
  if ids.len == 0: return
  progress("Syncing game saves")
  let negotiated = client.jsonRequest("POST", "/api/sync/negotiate", $(%*{
    "device_id": client.credentials.deviceId, "saves": saves, "rom_ids": ids,
    "restore_unlisted": true}))
  let session = negotiated.intField("session_id")
  var
    completed = 0
    failed = 0
    failure: string
  for operation in negotiated["operations"]:
    if operation.stringField("slot") != "autosave": continue
    var game: LibraryGame
    for local in index.games:
      if local.rommId == operation.intField("rom_id"): game = local; break
    if game == nil: continue
    let path = paths.savePath(game)
    try:
      case operation.stringField("action")
      of "upload": client.uploadSave(game, path, session)
      of "download":
        let content = client.receiveSave(paths, game, operation, session)
        if fileExists(path) and readFile(path) != content:
          discard writeNewSave(path & ".before-romm", readFile(path))
        writeSave(path, content)
        client.acknowledgeSave(operation, content)
      of "conflict", "delete":
        game.saveConflict = true
        raise newException(IOError, "Save needs review in RomM: " & game.title & "; local progress is unchanged")
      of "no_op": discard
      else: raise newException(IOError, "Unrecognized RomM save operation")
      game.saveConflict = false
      inc completed
    except CatchableError as error:
      inc failed
      failure = error.msg
  paths.saveIndex(index)
  discard client.jsonRequest("POST", "/api/sync/sessions/" & $session & "/complete",
    $(%*{"operations_completed": completed, "operations_failed": failed}))
  if failed > 0: raise newException(IOError, failure)

proc resolveSave*(client: RommClient, paths: LibraryPaths, config: LibraryConfig,
    index: LibraryIndex, hash, choice: string) =
  ## Apply an explicit conflict choice while preserving both available versions.
  paths.requireStorage(config)
  if choice notin ["local", "server"]: raise newException(ValueError, "Choose local or server")
  var game: LibraryGame
  for local in index.games:
    if local.hash == hash: game = local; break
  if game == nil or not game.saveConflict or game.rommOrigin != client.credentials.origin:
    raise newException(ValueError, "No save conflict for this game and server")
  let
    path = paths.savePath(game)
    localContent = if fileExists(path): readFile(path) else: ""
    saves = if localContent.len > 0: %*[{"rom_id": game.rommId,
      "file_name": game.hash & ".srm", "slot": "autosave", "content_hash": getMD5(localContent),
      "file_size_bytes": localContent.len,
      "updated_at": getLastModificationTime(path).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")}] else: newJArray()
    response = client.jsonRequest("POST", "/api/sync/negotiate", $(%*{
      "device_id": client.credentials.deviceId, "saves": saves,
      "rom_ids": [game.rommId], "restore_unlisted": true}))
    session = response.intField("session_id")
  var applied = 0
  for operation in response["operations"]:
    if operation.intField("rom_id") != game.rommId or operation.stringField("slot") != "autosave": continue
    let action = operation.stringField("action")
    if action in ["conflict", "download"]:
      let serverContent = client.receiveSave(paths, game, operation, session)
      discard writeNewSave(path & ".server-before-resolution", serverContent)
      if choice == "server":
        if localContent.len > 0: discard writeNewSave(path & ".local-before-resolution", localContent)
        writeSave(path, serverContent)
      client.acknowledgeSave(operation, serverContent)
      if choice == "local": client.uploadSave(game, path, session)
    elif action == "delete":
      if choice == "server" and fileExists(path):
        discard writeNewSave(path & ".before-server-deletion", localContent)
        removeFile(path)
      elif choice == "local": client.uploadSave(game, path, session)
    elif action == "upload": client.uploadSave(game, path, session)
    elif action != "no_op": raise newException(IOError, "Unrecognized save conflict operation")
    inc applied
  if applied == 0: raise newException(IOError, "The save changed on RomM; sync and review it again")
  discard client.jsonRequest("POST", "/api/sync/sessions/" & $session & "/complete",
    $(%*{"operations_completed": applied, "operations_failed": 0}))
  game.saveConflict = false
  paths.saveIndex(index)
