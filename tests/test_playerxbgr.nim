import
  std/[os, strutils, tempfiles],
  pixie,
  retro/[libretro, playerformats, playervideo, playerworker]

proc main() =
  ## Check private format negotiation, padded row copies, duplicates and fallback.
  when cpuEndian == littleEndian:
    for width in 1 .. 65:
      let pitch = width * 4 + 3
      var
        bytes = newSeq[uint8](1 + pitch * 3)
        expected: seq[ColorRGBX]
      for y in 0 .. 2:
        for x in 0 ..< width:
          let
            r = uint8((x * 17 + y * 3) mod 256)
            g = uint8((x * 41 + y * 7) mod 256)
            b = uint8((x * 73 + y * 11) mod 256)
            offset = 1 + y * pitch + x * 4
          bytes[offset] = r
          bytes[offset + 1] = g
          bytes[offset + 2] = b
          bytes[offset + 3] = 255
          expected.add(rgbx(r, g, b, 255))
      let image = copyFrame(nil, addr bytes[1], width, 3, pitch, PixelXbgr8888)
      doAssert image.data == expected
      doAssert copyFrame(image, nil, 0, 0, 0, PixelXbgr8888) == image
      bytes[1] = 255 - bytes[1]
      doAssert image.data == expected
      doAssert copyFrame(image, addr bytes[1], width, 3, pitch, PixelXbgr8888) == image
      doAssert image.data[0].r == bytes[1]
      var rejected = false
      try: discard copyFrame(nil, addr bytes[1], width, 3, width * 4 - 1, PixelXbgr8888)
      except ValueError: rejected = true
      doAssert rejected

  let
    directory = createTempDir("player-xbgr-", "")
    rom = directory / "fixture.test"
    trace = directory / "trace"
    core = absolutePath("build/player-fixture.so")
    expected = @[rgbx(255, 0, 0, 255), rgbx(0, 255, 0, 255), rgbx(0, 0, 255, 255),
      rgbx(255, 255, 255, 255), rgbx(128, 128, 128, 255), rgbx(0, 0, 0, 255)]
  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  defer:
    delEnv("MONO_RETRO_FIXTURE_TRACE")
    removeDir(directory)
  for mode in ["X", "C"]:
    writeFile(rom, mode)
    let session = openCore(core, rom, directory / mode)
    when cpuEndian == littleEndian:
      doAssert session.pixelFormat == (if mode == "X": int(MonoRetroXbgr8888) else: PixelXrgb8888)
    else:
      doAssert session.pixelFormat == PixelXrgb8888
    session.step(0)
    doAssert session.failure.len == 0 and session.image.data == expected
    session.step(0)
    doAssert session.image.data == expected
    doAssert session.videoFrames == (if mode == "X": 1'u64 else: 2'u64)
    session.close()
  doAssert readFile(trace).contains("format_rejected=1\n")
  doAssert readFile(trace).contains("xbgr_accepted=" & (if cpuEndian == littleEndian: "1" else: "0") & "\n")

  writeFile(rom, "X")
  let worker = openCoreWorker(core, rom, directory / "worker", captureAudio = true)
  worker.prefetch(256)
  worker.step(0)
  doAssert worker.image.data == expected
  doAssert worker.takeAudio() == @[10'i16, -10, 100, -100, 200, -200]
  worker.prefetch(0)
  worker.step(0)
  doAssert worker.image.data == expected and worker.videoFrames == 1
  worker.prefetch(0)
  worker.close()
  doAssert readFile(trace).endsWith("unload=1\ndeinit=1\n")

main()
