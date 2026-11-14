import
  std/[json, md5, net, os, osproc, strutils, tempfiles, times],
  retro/[gamelibrary, playersave, rommclient]

const
  RomBytes = "synthetic DS cartridge"
  RemoteSave = "verified remote save"
  TestToken = "rmm_synthetic_test_token"

proc serve(root: string) =
  ## Serve a bounded, loopback-only RomM fixture without real account access.
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  writeFile(root / "port", $server.getLocalAddr()[1].int)
  var stopping = false
  while not stopping:
    var client: Socket
    server.accept(client)
    let first = client.recvLine().splitWhitespace()
    if first.len < 2: client.close(); continue
    let
      verb = first[0]
      path = first[1]
    var
      length = 0
      authorized = false
    while true:
      let line = client.recvLine()
      if line.strip().len == 0: break
      if line.toLowerAscii().startsWith("content-length:"):
        length = parseInt(line.split(':', 1)[1].strip())
      if line == "Authorization: Bearer " & TestToken: authorized = true
    let body = if length > 0: client.recv(length) else: ""
    var
      status = "200 OK"
      response = "{}"
    if path == "/stop": stopping = true
    elif path == "/api/auth/device/init":
      doAssert not body.contains("password")
      response = $(%*{"device_code": "private-fixture-code", "user_code": "TESTCODE",
        "verification_path": "/pair/device", "verification_path_complete": "/pair/device?user_code=TESTCODE",
        "interval": 1, "expires_in": 10})
    elif path == "/api/auth/device/token":
      let mode = readFile(root / "pair-mode")
      if mode == "approved":
        response = $(%*{"access_token": TestToken, "device_id": "fixture-device"})
      else:
        status = "400 Bad Request"
        response = $(%*{"detail": mode})
    elif not authorized:
      status = "401 Unauthorized"
    elif path == "/api/collections":
      response = "[{\"id\":7,\"name\":\"Handheld games\"}]"
    elif path.startsWith("/api/roms/by-hash"):
      status = "404 Not Found"
    elif path.startsWith("/api/roms?"):
      response = $(%*{"items": [{"id": 15, "fs_name": "Fixture.nds",
        "fs_size_bytes": RomBytes.len, "sha1_hash": fileHash(root / "rom"),
        "name": "Fixture game", "path_cover_small": "", "summary": "Fixture"}]})
    elif path.startsWith("/api/roms/15/content/"):
      response = RomBytes
    elif path == "/api/sync/negotiate":
      let mode = readFile(root / "save-mode")
      response = $(%*{"session_id": 42, "operations": [{"action": (if mode == "named": "download" else: mode),
        "rom_id": 15, "save_id": 8, "file_name": "Fixture.srm",
        "slot": (if mode == "named": "checkpoint" else: "autosave"),
        "server_content_hash": getMD5(RemoteSave)}]})
    elif path.startsWith("/api/saves/8/content"):
      doAssert path.contains("optimistic=false")
      response = RemoteSave
    elif path == "/api/saves/8/downloaded":
      doAssert parseJson(body).stringField("content_hash") == getMD5(RemoteSave)
      writeFile(root / "acknowledged", "yes")
    elif path.startsWith("/api/saves?") and verb == "POST":
      doAssert path.contains("overwrite=false")
      doAssert body.contains("name=\"saveFile\"")
      writeFile(root / "uploaded", body)
    elif path == "/api/sync/sessions/42/complete":
      writeFile(root / "completed", body)
    elif path == "/truncated":
      client.send("HTTP/1.1 200 OK\r\nContent-Length: 999\r\nConnection: close\r\n\r\nshort")
      client.close()
      continue
    else: status = "404 Not Found"
    client.send("HTTP/1.1 " & status & "\r\nContent-Length: " & $response.len &
      "\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" & response)
    client.close()
  server.close()

proc rejected(action: proc()) =
  ## Require failed authorization or transfer to remain an explicit failure.
  var raised = false
  try: action()
  except CatchableError: raised = true
  doAssert raised

proc main() =
  ## Exercise pairing, collection downloads and guarded save operations end to end.
  if paramCount() == 2 and paramStr(1) == "serve": serve(paramStr(2)); return
  let root = createTempDir("mono-retro-romm-test-", "")
  defer: removeDir(root)
  writeFile(root / "rom", RomBytes)
  writeFile(root / "pair-mode", "authorization_pending")
  writeFile(root / "save-mode", "no_op")
  let server = startProcess(getAppFilename(), args = @["serve", root], options = {poParentStreams})
  defer:
    if server.running(): server.terminate()
    discard server.waitForExit()
    server.close()
  let deadline = epochTime() + 5
  while not fileExists(root / "port") and epochTime() < deadline: sleep(10)
  doAssert fileExists(root / "port")
  let
    origin = "http://127.0.0.1:" & readFile(root / "port")
    paths = libraryPaths(root, root / "config" / "library.json")
    config = LibraryConfig(playerPath: "/player", rommUrl: origin,
      cores: @[CoreConfig(key: "ds", path: "/core", platforms: @["nds"])])
    client = newRommClient(origin)
  defer: client.close()
  paths.prepareStorage(config)
  let flow = client.beginPairing("fixture", "Fixture device")
  doAssert flow.stringField("user_code") == "TESTCODE"
  doAssert client.pairingUrl(flow) == origin & "/pair/device?user_code=TESTCODE"
  for path in ["", "https://different.example/pair/device", "//different.example/pair", "/\\different.example"]:
    rejected(proc() = discard client.pairingUrl(%*{"verification_path_complete": path}))
  doAssert not client.pollPairing("private-fixture-code", paths.credentials)
  doAssert not fileExists(paths.credentials)
  writeFile(root / "pair-mode", "access_denied")
  rejected(proc() = discard client.pollPairing("private-fixture-code", paths.credentials))
  writeFile(root / "pair-mode", "expired_token")
  rejected(proc() = discard client.pollPairing("private-fixture-code", paths.credentials))
  writeFile(root / "pair-mode", "approved")
  doAssert client.pollPairing("private-fixture-code", paths.credentials)
  doAssert getFilePermissions(paths.credentials) == {fpUserRead, fpUserWrite}
  rejected(proc() = discard loadCredentials(paths.credentials, "https://different.example"))
  rejected(proc() = discard apiOrigin("http://example.com"))
  rejected(proc() = discard apiOrigin("https://user:password@example.com"))
  let connected = newRommClient(origin, loadCredentials(paths.credentials, origin))
  defer: connected.close()
  var index = paths.loadIndex()
  proc progress(message: string) =
    ## Assert synthetic status never contains the token or private polling code.
    doAssert TestToken notin message and "private-fixture-code" notin message
  connected.syncCatalogue(paths, config, index, progress)
  doAssert index.collections.len == 1
  doAssert index.games.len == 0
  index.collections[0].selected = true
  connected.syncCatalogue(paths, config, index, progress)
  doAssert index.games.len == 1
  let game = index.games[0]
  doAssert readFile(root / game.path) == RomBytes
  doAssert game.rommId == 15
  doAssert game.rommOrigin == origin
  let save = paths.gameSaveDir(game) / "Fixture.srm"
  createDir(save.parentDir)
  writeSave(save, "original local save")
  writeFile(root / "save-mode", "conflict")
  rejected(proc() = connected.syncSaves(paths, config, index, progress))
  doAssert readFile(save) == "original local save"
  doAssert game.saveConflict
  connected.resolveSave(paths, config, index, game.hash, "server")
  doAssert readFile(save) == RemoteSave
  doAssert readFile(save & ".local-before-resolution") == "original local save"
  doAssert readFile(save & ".server-before-resolution") == RemoteSave
  doAssert not game.saveConflict
  doAssert fileExists(root / "acknowledged")
  writeFile(root / "save-mode", "delete")
  rejected(proc() = connected.syncSaves(paths, config, index, progress))
  doAssert readFile(save) == RemoteSave
  connected.resolveSave(paths, config, index, game.hash, "local")
  doAssert readFile(save) == RemoteSave
  doAssert fileExists(root / "uploaded")
  writeFile(root / "save-mode", "download")
  connected.syncSaves(paths, config, index, progress)
  doAssert readFile(save) == RemoteSave
  let download = root / "download"
  writeFile(root / "save-mode", "named")
  writeSave(save, "preserve active autosave")
  connected.syncSaves(paths, config, index, progress)
  doAssert readFile(save) == "preserve active autosave"
  writeFile(download, "keep existing")
  rejected(proc() = connected.download("/truncated", download, 999))
  doAssert readFile(download) == "keep existing"
  rejected(proc() = connected.download("/api/roms/15/content/Fixture.nds", download, RomBytes.len, repeat('0', 40)))
  doAssert readFile(download) == "keep existing"
  let offline = newRommClient("http://127.0.0.1:1")
  defer: offline.close()
  rejected(proc() = discard offline.jsonRequest("GET", "/api/collections"))
  rejected(proc() = offline.download("/api/unreachable", download, 10))
  doAssert readFile(download) == "keep existing"
  discard connected.request("GET", "/api/not-found")
  doAssert fileExists(root / "completed")

main()
