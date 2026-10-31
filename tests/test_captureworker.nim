import
  std/[algorithm, os, sha1, strutils, tempfiles],
  pixie,
  retro/[libretro, playercapture, playerworker]

proc segments(directory: string): seq[string] =
  ## Locate segment manifests independently of the session timestamp.
  for path in walkFiles(directory / "segment_*.json"):
    result.add(path)
  result.sort()

proc main() =
  ## Exercise real ABI recording, prefetched-frame snapshots, imports and exact replay.
  let
    directory = createTempDir("capture-worker-", "")
    rom = directory / "fixture.test"
    core = absolutePath("build/player-fixture.so")
  defer: removeDir(directory)
  writeFile(rom, "V")
  let worker = openCoreWorker(core, rom, directory / "saves",
    captureAudio = true, captureDirectory = directory / "captures",
    screenstateDirectory = directory / "Pictures" / "Screenshots")
  doAssert worker.stateExport
  let sessionDirectory = worker.captureDirectory
  worker.step(0)
  worker.prefetch(256)
  worker.capture(reason = "auto", withState = false)
  worker.capture()
  let frameTwo = worker.exportState()
  worker.step(0)
  doAssert worker.frames == 2
  worker.step(0)
  doAssert worker.frames == 3 and worker.videoFrames == 2
  worker.capture()
  let firstEnd = worker.exportState()
  worker.importStateData("fixture-state", "new segment")
  worker.step(256, PointerInput(x: 12, y: -34, pressed: true))
  worker.prefetch(0)
  let secondEnd = worker.exportState()
  worker.close()
  worker.close()

  let recordings = segments(sessionDirectory)
  doAssert recordings.len == 2
  let
    first = readReplay(recordings[0])
    second = readReplay(recordings[1])
  doAssert first.inputs.len == 3
  doAssert first.inputs[0].buttons == 0 and first.inputs[1].buttons == 256 and
    first.inputs[2].buttons == 0
  doAssert second.inputs.len == 2
  doAssert second.inputs[0].buttons == 256
  doAssert second.inputs[0].pointerInput == PointerInput(x: 12, y: -34, pressed: true)
  doAssert second.inputs[1].buttons == 0
  var
    pngs, embedded = 0
    foundFrameTwo, foundDuplicate = false
  for path in walkFiles(sessionDirectory / "*.png"):
    inc pngs
    let contents = readFile(path)
    let image = readImage(path)
    doAssert image.width == 3 and image.height == 2
    if contents.contains("mrSt"):
      inc embedded
      let state = unwrapScreenstate(contents, $secureHashFile(rom), $secureHashFile(core))
      if state == frameTwo:
        foundFrameTwo = true
        doAssert image.data[0] == rgbx(0, 255, 0, 255)
      elif state == firstEnd:
        foundDuplicate = true
        doAssert image.data[0] == rgbx(0, 255, 0, 255)
      else: doAssert state == secondEnd
  doAssert pngs == 4 and embedded == 3
  var archived = 0
  for path in walkFiles(directory / "Pictures" / "Screenshots" / "*.png"):
    inc archived
    doAssert readFile(path) == readFile(sessionDirectory / path.extractFilename)
    doAssert readFile(path).contains("mrSt")
  doAssert archived == 3
  doAssert foundFrameTwo and foundDuplicate
  for index, path in recordings:
    let replay = openCoreWorker(core, rom, directory / ("replay-" & $index),
      captureAudio = true, replayPath = path)
    while not replay.shutdown: replay.step(65535, PointerInput(pressed: true))
    doAssert replay.frames == (if index == 0: 3'u64 else: 2'u64)
    doAssert replay.exportState() == (if index == 0: firstEnd else: secondEnd)
    replay.close()

  let
    checkpointPath = recordings[0].changeFileExt("state")
    checkpoint = readFile(checkpointPath)
    seedDirectory = directory / "empty-replay"
    seed = repeat('s', 16)
  createDir(seedDirectory)
  writeFile(seedDirectory / "fixture.srm", seed)
  writeFile(checkpointPath, "")
  var rejectedEmpty = false
  try: discard openCoreWorker(core, rom, seedDirectory, replayPath = recordings[0])
  except IOError: rejectedEmpty = true
  doAssert rejectedEmpty and readFile(seedDirectory / "fixture.srm") == seed
  writeFile(checkpointPath, checkpoint)

  let unsupported = openCoreWorker(absolutePath("build/player-fullpath.so"), rom,
    directory / "unsupported", captureDirectory = directory / "captures")
  doAssert not unsupported.stateExport
  unsupported.step(0)
  unsupported.capture(reason = "auto", withState = false)
  var rejected = false
  try: unsupported.capture()
  except IOError as error: rejected = error.msg.contains("does not support")
  doAssert rejected
  unsupported.close()

  writeFile(rom, "J")
  let trace = directory / "import-failure-trace"
  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  defer: delEnv("MONO_RETRO_FIXTURE_TRACE")
  let failing = openCoreWorker(core, rom, directory / "failing",
    captureAudio = true, captureDirectory = directory / "captures")
  failing.step(0)
  failing.prefetch(256)
  discard failing.exportState()
  let completed = readFile(trace).count("video_returned=")
  rejected = false
  try: failing.importStateData("fixture-state", "accepted import")
  except IOError as error: rejected = error.msg.contains("State restored")
  doAssert rejected and failing.shutdown
  doAssert failing.image == nil and failing.takeAudio().len == 0
  doAssert readFile(trace).contains("state_loaded=42")
  failing.step(0)
  doAssert readFile(trace).count("video_returned=") == completed
  rejected = false
  try: failing.close()
  except IOError as error: rejected = error.msg.contains("State restored")
  doAssert rejected
  failing.close()

  echo "Worker capture/replay round-trips passed."

main()
