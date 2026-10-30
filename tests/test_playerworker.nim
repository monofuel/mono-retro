import
  std/[os, strutils, tempfiles],
  pixie,
  retro/[libretro, playerworker]

proc main() =
  ## Verify threaded frame ownership, duplicates, state operations and cleanup.
  let
    directory = createTempDir("player-worker-", "")
    trace = directory / "trace"
    rom = directory / "fixture.test"
    core = absolutePath("build/player-fixture.so")
    samples = @[10'i16, -10, 100, -100, 200, -200]
  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  defer:
    delEnv("MONO_RETRO_FIXTURE_TRACE")
    removeDir(directory)
  writeFile(rom, "V")
  let worker = openCoreWorker(core, rom, directory / "buffers", captureAudio = true)
  doAssert worker.libraryName == "Player fixture" and worker.libraryVersion == "1"
  doAssert worker.av.geometry.baseWidth == 3 and worker.av.timing.fps == 60
  worker.step(256, PointerInput(x: 12, y: 34, pressed: true), compareVideo = true)
  doAssert worker.imageChanged
  doAssert worker.frames == 1 and worker.image.data[0] == rgbx(255, 0, 0, 255)
  doAssert worker.takeAudio() == samples
  doAssert worker.takeAudio().len == 0
  worker.prefetch(0)
  worker.save()
  doAssert worker.frames == 1
  worker.step(256, compareVideo = true)
  doAssert worker.imageChanged
  doAssert worker.frames == 2 and worker.image.data[0] == rgbx(0, 255, 0, 255)
  worker.prefetch(0)
  worker.step(0, compareVideo = true)
  doAssert not worker.imageChanged
  doAssert worker.frames == 3 and worker.videoFrames == 2
  doAssert worker.image.data[0] == rgbx(0, 255, 0, 255)
  worker.prefetch(0)
  worker.pause()
  worker.step(0, compareVideo = true)
  doAssert worker.imageChanged
  doAssert worker.frames == 4 and worker.takeAudio().len == 0
  doAssert worker.image.data[0] == rgbx(0, 0, 255, 255)
  worker.prefetch(0)
  var rejected = false
  try: worker.importStateData("bad-state", "bad drop")
  except IOError as error:
    rejected = error.msg.contains("Core rejected")
  doAssert rejected
  worker.step(0, compareVideo = true)
  doAssert not worker.imageChanged
  doAssert worker.frames == 5 and worker.image.data[0] == rgbx(0, 0, 255, 255)
  worker.prefetch(0)
  worker.importStateData("fixture-state", "live drop")
  doAssert worker.takeAudio().len == 0
  worker.step(0)
  doAssert worker.frames == 7 and worker.image.data[0] == rgbx(255, 0, 0, 255)
  worker.prefetch(256)
  worker.close()
  worker.close()
  doAssert readFile(worker.savePath)[1] == char(1)
  doAssert readFile(trace).endsWith("unload=1\ndeinit=1\n")
  doAssert readFile(trace).contains("pointer_pressed=1\npointer_x=12\npointer_y=34\n")

  writeFile(rom, "R")
  let rate = openCoreWorker(core, rom, directory / "rate", captureAudio = true)
  rate.step(0)
  rate.prefetch(0)
  rate.step(0)
  doAssert rate.av.timing.sampleRate == 44100
  rate.close()

  for mode in ["B", "H", "F", "I"]:
    writeFile(rom, mode)
    var broken: CoreWorker
    rejected = false
    try:
      broken = openCoreWorker(core, rom, directory / mode, captureAudio = true)
      broken.prefetch(0)
      broken.step(0)
    except IOError:
      rejected = true
    finally:
      broken.close()
    doAssert rejected
  writeFile(rom, "D")
  let badSave = openCoreWorker(core, rom, directory / "save-error")
  badSave.step(0)
  createDir(badSave.savePath)
  rejected = false
  try: badSave.close()
  except IOError: rejected = true
  doAssert rejected
  badSave.close()
  writeFile(rom, "Q")
  let last = openCoreWorker(core, rom, directory / "last")
  last.step(0)
  doAssert last.shutdown
  doAssert last.takeAudio().len == 0
  last.close()

main()
