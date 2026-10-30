import
  std/[json, os, strutils, tempfiles, unittest],
  retro/[ra_config, ra_types]

suite "Private RetroAchievements configuration":
  test "atomic private token storage and local logout":
    let directory = createTempDir("mono-retro-ra-", "")
    defer: removeDir(directory)
    let path = directory / "account.json"
    check loadRaCredentials(path).username.len == 0
    saveRaCredentials(path, RaCredentials(username: "SyntheticUser", token: "synthetic-token"))
    check getFilePermissions(path) == {fpUserRead, fpUserWrite}
    let document = parseFile(path)
    check document.len == 2
    check not document.hasKey("password")
    check loadRaCredentials(path).token == "synthetic-token"
    let original = readFile(path)
    expect ValueError:
      saveRaCredentials(path, RaCredentials(username: "", token: ""))
    check readFile(path) == original
    forgetRaCredentials(path)
    forgetRaCredentials(path)
    check not fileExists(path)

  test "malformed and public files fail without exposing contents":
    let directory = createTempDir("mono-retro-ra-", "")
    defer: removeDir(directory)
    let path = directory / "account.json"
    saveRaCredentials(path, RaCredentials(username: "Fixture", token: "do-not-log-me"))
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead})
    expect ValueError: discard loadRaCredentials(path)
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    for contents in ["{do-not-log-me", "[]", "{}", "{\"username\":4,\"token\":\"do-not-log-me\"}"]:
      writeFile(path, contents)
      var rejected = false
      try: discard loadRaCredentials(path)
      except ValueError as error:
        rejected = true
        check not error.msg.contains("do-not-log-me")
      check rejected

  test "explicit and empty-home service paths resolve consistently":
    let
      existed = existsEnv("HOME")
      previous = getEnv("HOME")
    defer:
      if existed: putEnv("HOME", previous)
      else: delEnv("HOME")
    putEnv("HOME", "/synthetic-home")
    check resolveRaConfig() == "/synthetic-home/" & RaConfigFilename
    check resolveRaConfig("build/ra/test-account.json").isAbsolute
    delEnv("HOME")
    let fallback = resolveRaConfig()
    check fallback.isAbsolute
    check fallback != "/" & RaConfigFilename
