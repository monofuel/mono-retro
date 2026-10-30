import std/[md5, os, strutils, tables, tempfiles]
import retro/[playerworker, ra_config, ra_http, ra_types]
import ./ra_fixture

when not defined(raTesting):
  {.error: "Worker achievement tests require -d:raTesting.".}

proc transport(request: RaHttpRequest): RaHttpResponse {.nimcall.} =
  ## Verify hashing uses the supplied source even if the core mutates its input.
  let fields = request.requestFields()
  if fields.getOrDefault("r") == "achievementsets":
    doAssert fields["m"] == getMD5("D" & repeat('\0', 32767))
  fixtureTransport(request)

proc main() =
  ## Verify real SDK evaluation on the core worker, including prefetched duplicates.
  let directory = createTempDir("ra-worker-", "")
  defer: removeDir(directory)
  let
    path = directory / "account.json"
    rom = directory / "synthetic.sfc"
  saveRaCredentials(path, RaCredentials(username: "SyntheticUser", token: "synthetic-token"))
  var bytes = newString(32768)
  bytes[0] = 'D'
  writeFile(rom, bytes)
  setWorkerRaHttpTestHandler(transport)
  defer: setWorkerRaHttpTestHandler(nil)
  let worker = openCoreWorker(absolutePath("build/player-ra-fixture.so"), rom,
    directory / "saves", captureAudio = false, raConfigPath = path, achievementsEnabled = true)
  defer: worker.close()
  for index in 0 ..< 20: worker.idleAchievements(withList = true)
  doAssert worker.raSnapshot.status == RaReady
  doAssert worker.raSnapshot.achievements.len == 4
  worker.step(0, compareVideo = true)
  doAssert worker.takeRaNotices().len == 0
  worker.prefetch(0)
  worker.pause()
  doAssert worker.takeRaNotices().len == 1
  doAssert worker.takeRaNotices().len == 0
  worker.step(0, compareVideo = true)
  doAssert not worker.imageChanged
  doAssert worker.takeRaNotices().len == 0
  var rejected = false
  try: worker.importStateData("bad", "synthetic rejection")
  except IOError: rejected = true
  doAssert rejected
  worker.idleAchievements(withList = true)
  doAssert worker.raSnapshot.unlocked == 1
  worker.importStateData("fixture-state", "synthetic accepted state")
  worker.step(0)
  doAssert worker.takeRaNotices().len == 0
  worker.close()
  worker.close()

main()
