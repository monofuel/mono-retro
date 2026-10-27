import
  std/[os, strutils, tempfiles],
  pixie,
  retro/libretro

proc main() =
  ## Exercise C ABI lifecycle, callback failures and save persistence.
  let
    directory = createTempDir("player-core-", "")
    trace = directory / "trace"
    rom = directory / "fixture.test"
    core = absolutePath("build/player-fixture.so")

  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  defer:
    delEnv("MONO_RETRO_FIXTURE_TRACE")
    removeDir(directory)

  for name in ["player-fixture.so", "player-fullpath.so"]:
    writeFile(rom, "D")
    let session = openCore(absolutePath("build" / name), rom, directory / name)
    doAssert $session.info.libraryName == "Player fixture"
    doAssert session.av.geometry.baseWidth == 3 and session.av.timing.fps == 60
    session.step(256)
    doAssert session.image.data[0] == rgbx(255, 0, 0, 255)
    doAssert session.image.data[3] == rgbx(255, 255, 255, 255)
    session.step(0)
    doAssert session.frames == 2 and session.videoFrames == 1 and session.audioFrames == 6
    session.save()
    doAssert readFile(session.savePath)[4] == char(123)
    session.close()
    session.close()
    let again = openCore(absolutePath("build" / name), rom, directory / name)
    again.step(0)
    again.close()
    doAssert readFile(trace).contains("loaded_byte=123\n")

  for mode in ["B", "H", "F"]:
    writeFile(rom, mode)
    var
      rejected = false
      session: CoreSession
    try:
      session = openCore(core, rom, directory / mode)
      session.step(0)
    except IOError:
      rejected = true
    finally:
      if session != nil: session.close()
    doAssert rejected
  doAssert readFile(trace).contains("video_returned=1\n")
  doAssert readFile(trace).endsWith("deinit=1\n")

  writeFile(rom, "S")
  let session = openCore(core, rom, directory / "shrink")
  session.step(0)
  session.close()
  doAssert readFile(session.savePath).len == 8
  let again = openCore(core, rom, directory / "shrink")
  again.step(0)
  again.close()

  let oversized = directory / "oversized"
  createDir(oversized)
  writeFile(oversized / "fixture.srm", repeat('x', 32))
  var rejected = false
  try: discard openCore(core, rom, oversized)
  except IOError: rejected = true
  doAssert rejected
  doAssert readFile(oversized / "fixture.srm") == repeat('x', 32)

  rejected = false
  try: discard openCore(absolutePath("build/player-missing.so"), rom, directory / "missing")
  except IOError: rejected = true
  doAssert rejected
  writeFile(rom, "Q")
  let last = openCore(core, rom, directory / "last")
  last.step(0)
  doAssert last.shutdown
  last.close()

main()
