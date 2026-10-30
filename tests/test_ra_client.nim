import std/[json, monotimes, os, strutils, tables, tempfiles, times, unittest]
import retro/[ra_client, ra_config, ra_http, ra_types]
import ./ra_fixture

when not defined(raTesting):
  {.error: "These tests require -d:raTesting to prohibit real HTTP.".}

suite "Isolated RetroAchievements SDK":
  test "Casual login, ROM identity, RAM boundaries, unlocks and state reset":
    let directory = createTempDir("ra-client-", "")
    defer: removeDir(directory)
    var
      wram: array[131072, uint8]
      sram: array[8192, uint8]
      actions, hashes: seq[string]
      awards = 0
    proc transport(request: RaHttpRequest): RaHttpResponse =
      ## Capture synthetic calls while preserving the SDK's actual protocol.
      let fields = request.requestFields()
      actions.add(fields.getOrDefault("r"))
      if fields.getOrDefault("r") == "achievementsets": hashes.add(fields["m"])
      if fields.getOrDefault("r") == "awardachievement": inc awards
      fixtureTransport(request)
    proc memory(id: uint32): RaMemoryInfo =
      ## Expose only actual SNES WRAM and cartridge SRAM extents.
      case id
      of 2: RaMemoryInfo(data: addr wram[0], size: wram.len)
      of 0: RaMemoryInfo(data: addr sram[0], size: sram.len)
      else: RaMemoryInfo()
    setRaHttpTestHandler(transport)
    defer: setRaHttpTestHandler(nil)
    let credentials = loginRa("SyntheticUser", "synthetic-password")
    check credentials.username == "SyntheticUser"
    check credentials.token == "synthetic-token"
    let path = directory / "account.json"
    saveRaCredentials(path, credentials)
    let rom = newString(32768)
    let runtime = newRaRuntime(path, true, true, "synthetic.sfc", rom, memory)
    defer: runtime.close()
    for index in 0 ..< 20: runtime.idle()
    check runtime.snapshot().status == RaReady
    check runtime.snapshot().total == 4
    check not runtime.snapshot().hasList
    check runtime.snapshot().achievements.len == 0
    check runtime.snapshot(true).achievements.len == 4
    runtime.frame()
    wram[0] = 2
    wram[^1] = 9
    sram[0] = 7
    sram[^1] = 8
    runtime.frame()
    check runtime.takeNotices().len == 4
    check runtime.takeNotices().len == 0
    for index in 0 ..< 4: runtime.idle()
    check awards == 4
    for achievement in runtime.snapshot(true).achievements: check achievement.unlocked
    runtime.resetProgress()
    runtime.refreshMemory()
    runtime.frame()
    check runtime.takeNotices().len == 0
    runtime.close()
    runtime.close()
    let headered = newRaRuntime(path, true, true, "headered.smc", repeat('x', 512) & rom, memory)
    for index in 0 ..< 20: headered.idle()
    check headered.snapshot().status == RaReady
    headered.close()
    check hashes.len == 2
    check hashes[0] == hashes[1]

  test "Optional failures and rejected credentials never expose service text":
    let directory = createTempDir("ra-client-errors-", "")
    defer: removeDir(directory)
    let path = directory / "account.json"
    let disabled = newRaRuntime(path, false, false, "", "", nil)
    check disabled == nil
    disabled.frame()
    disabled.idle()
    disabled.close()
    check newRaRuntime(path, true, false, "", "", nil).snapshot().status == RaUnavailable
    check newRaRuntime(path, true, true, "", "", nil).snapshot().status == RaUnconfigured
    saveRaCredentials(path, RaCredentials(username: "SyntheticUser", token: "old-token"))
    setRaHttpTestHandler(proc(request: RaHttpRequest): RaHttpResponse =
      ## Deliberately return secret-bearing remote text to test sanitization.
      RaHttpResponse(status: 401, body: "{\"Success\":false,\"Error\":\"synthetic-secret\"}"))
    defer: setRaHttpTestHandler(nil)
    expect IOError: discard loginRa("SyntheticUser", "bad-password")
    check loadRaCredentials(path).token == "old-token"
    let failed = newRaRuntime(path, true, true, "synthetic.sfc", newString(32768), nil)
    for index in 0 ..< 5: failed.idle()
    check failed.snapshot().status == RaFailed
    check "synthetic-secret" notin failed.snapshot().message
    failed.close()
    setRaHttpTestHandler(nil)
    expect ValueError: discard newRaHttp()
    let
      previousHome = getEnv("HOME")
      hadHome = existsEnv("HOME")
    try:
      putEnv("HOME", "relative-invalid-home")
      check newRaRuntime("", false, true, "", "", nil) == nil
      check newRaRuntime("", true, false, "", "", nil).snapshot().status == RaUnavailable
      check newRaRuntime("", true, true, "", "", nil).snapshot().status == RaFailed
    finally:
      if hadHome: putEnv("HOME", previousHome)
      else: delEnv("HOME")

  test "submission retries progress during pause and outstanding startup can close":
    let directory = createTempDir("ra-retries-", "")
    defer: removeDir(directory)
    let path = directory / "account.json"
    saveRaCredentials(path, RaCredentials(username: "SyntheticUser", token: "synthetic-token"))
    var
      wram: array[131072, uint8]
      sram: array[8192, uint8]
      attempts = 0
    proc memory(id: uint32): RaMemoryInfo =
      ## Provide stable synthetic memory while the network reconnects.
      case id
      of 2: RaMemoryInfo(data: addr wram[0], size: wram.len)
      of 0: RaMemoryInfo(data: addr sram[0], size: sram.len)
      else: RaMemoryInfo()
    proc transport(request: RaHttpRequest): RaHttpResponse =
      ## Fail two submissions so the actual SDK schedules its timed retry.
      let action = request.requestFields().getOrDefault("r")
      if action == "awardachievement":
        inc attempts
        if attempts <= 2: return RaHttpResponse(error: RaHttpTransportError)
      result = fixtureTransport(request)
      if action == "achievementsets":
        var document = parseJson(result.body)
        let first = document["Sets"][0]["Achievements"][0]
        document["Sets"][0]["Achievements"] = %*[first]
        result.body = $document
    setRaHttpTestHandler(transport)
    defer: setRaHttpTestHandler(nil)
    for pendingStage in 0 .. 2:
      let pending = newRaRuntime(path, true, true, "synthetic.sfc", newString(32768), memory)
      for index in 0 ..< pendingStage: pending.idle()
      pending.close()
      pending.close()
    let runtime = newRaRuntime(path, true, true, "synthetic.sfc", newString(32768), memory)
    defer: runtime.close()
    for index in 0 ..< 20: runtime.idle()
    check runtime.snapshot().total == 1
    runtime.frame()
    wram[0] = 2
    runtime.frame()
    check runtime.takeNotices().len == 1
    for index in 0 ..< 8: runtime.idle()
    check attempts == 2
    check runtime.snapshot().message.contains("Offline")
    let deadline = getMonoTime() + initDuration(seconds = 3)
    while attempts < 3 and getMonoTime() < deadline:
      runtime.idle()
      sleep(10)
    runtime.idle()
    check attempts == 3
    check runtime.snapshot().message.len == 0
    check runtime.takeNotices().len == 0
