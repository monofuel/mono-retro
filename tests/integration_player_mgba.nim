import
  std/[os, strutils, tempfiles],
  pixie,
  retro/libretro

proc main() =
  ## Smoke-test a separately supplied mGBA core and Mother 3 working copy.
  doAssert paramCount() == 2, "Supply the mGBA core path and an uncompressed Mother 3 ROM."
  let
    directory = createTempDir("player-mgba-", "")
    session = openCore(paramStr(1), paramStr(2), directory)
  defer: removeDir(directory)
  try:
    doAssert ($session.info.libraryName).toLowerAscii.contains("mgba")
    doAssert session.av.timing.fps > 59 and session.av.timing.fps < 60
    var varied = false
    for frame in 0 ..< 1800:
      session.step(if frame mod 120 < 10: 1'u16 shl 3 else: 0'u16)
      for pixel in session.image.data:
        if pixel != session.image.data[0]: varied = true
    doAssert session.image.width == 240 and session.image.height == 160
    doAssert session.videoFrames == 1800 and session.audioFrames > 0
    doAssert varied
    session.image.writeFile("build/player-test/mgba-smoke.png")
    session.save()
  finally:
    session.close()
  let
    contents = readFile(session.savePath)
    again = openCore(paramStr(1), paramStr(2), directory)
  try:
    for frame in 0 ..< 30: again.step(0)
  finally:
    again.close()
  doAssert readFile(session.savePath) == contents

main()
