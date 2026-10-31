import
  std/[json, os, strutils, tempfiles],
  pixie,
  zippy/crc,
  retro/[libretro, playercapture, playerworker]

const Frames = 60

proc main() =
  ## Verify private EarthBound state capture and replay without opening audio or a window.
  if paramCount() != 3:
    raise newException(ValueError, "Usage: integration_decompbound_capture CORE ROM STATE_PNG")
  let
    directory = createTempDir("decompbound-capture-", "")
    options: seq[CoreOption] = @[("decompbound_dual_screen", "enabled")]
  defer: removeDir(directory)
  var expected: seq[tuple[video, audio: uint32]]
  let live = openCoreWorker(absolutePath(paramStr(1)), absolutePath(paramStr(2)),
    directory / "live", captureAudio = true, options = options,
    statePath = absolutePath(paramStr(3)), captureDirectory = directory / "captures")
  let sessionDirectory = live.captureDirectory
  var capturedState: string
  for frame in 0 ..< Frames:
    live.step(if frame < 20: 1'u16 shl 7 else: 0)
    let samples = live.takeAudio()
    doAssert live.image != nil and samples.len > 0
    expected.add((crc32(unsafeAddr live.image.data[0], live.image.data.len * 4),
      crc32(unsafeAddr samples[0], samples.len * 2)))
    if frame == 29:
      capturedState = live.exportState()
      live.capture()
  let finalState = live.exportState()
  live.close()

  var segment, manual: string
  for path in walkFiles(sessionDirectory / "segment_*.json"): segment = path
  for path in walkFiles(sessionDirectory / "*.png"):
    if parseFile(path.changeFileExt("json"))["reason"].getStr == "manual": manual = path
  doAssert segment.len > 0 and manual.len > 0
  let recording = readReplay(segment)
  doAssert recording.inputs.len == Frames
  doAssert recording.checkpoint.startsWith("DBST")
  doAssert recording.checkpoint.len < 1024 * 1024, "Checkpoint retained libretro padding"
  let replay = openCoreWorker(absolutePath(paramStr(1)), absolutePath(paramStr(2)),
    directory / "replay", captureAudio = true, options = options, replayPath = segment)
  var index = 0
  while not replay.shutdown:
    replay.step(65535)
    let samples = replay.takeAudio()
    doAssert index < expected.len
    doAssert crc32(unsafeAddr replay.image.data[0], replay.image.data.len * 4) == expected[index].video,
      "Replay video mismatch at frame " & $index
    doAssert crc32(unsafeAddr samples[0], samples.len * 2) == expected[index].audio,
      "Replay PCM mismatch at frame " & $index
    inc index
  doAssert index == Frames and replay.exportState() == finalState
  replay.close()
  let resumed = openCoreWorker(absolutePath(paramStr(1)), absolutePath(paramStr(2)),
    directory / "resumed", options = options, statePath = manual)
  doAssert resumed.exportState() == capturedState
  resumed.close()
  echo "EarthBound dual-screen capture, per-frame pixels/PCM and final state matched."

main()
