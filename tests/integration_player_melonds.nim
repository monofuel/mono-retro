import
  std/[os, tempfiles],
  pixie,
  retro/[libretro, playerds]

proc main() =
  ## Verify real DS video/audio and save restoration using disposable SRAM copies.
  doAssert paramCount() == 3, "Supply the melonDS DS core, ROM and seed save paths."
  let
    directory = createTempDir("player-melonds-", "")
    seed = readFile(paramStr(3))
    savePath = directory / paramStr(2).splitFile.name & ".srm"
  defer: removeDir(directory)
  copyFile(paramStr(3), savePath)
  let session = openCore(paramStr(1), paramStr(2), directory,
    captureAudio = true, options = DsOptions)
  try:
    doAssert $session.info.libraryName == "melonDS DS"
    doAssert session.av.timing.fps > 59 and session.av.timing.fps < 60
    session.save()
    doAssert readFile(savePath) == seed
    var varied = false
    for frame in 0 ..< 600:
      session.step(0)
      validateDsFrame(session.image.width, session.image.height)
      let samples = session.takeAudio()
      doAssert samples.len > 0 and samples.len mod 2 == 0
      if not session.image.isOneColor(): varied = true
    doAssert varied and session.audioFrames > 0
  finally:
    session.close()
  let
    saved = readFile(savePath)
    restored = openCore(paramStr(1), paramStr(2), directory, options = DsOptions)
  try:
    restored.save()
    doAssert readFile(savePath) == saved
    restored.step(0)
  finally:
    restored.close()
  doAssert readFile(paramStr(3)) == seed

main()
