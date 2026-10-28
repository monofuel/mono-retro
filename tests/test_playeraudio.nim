import
  std/[math, monotimes, os, times],
  retro/[libretro, playeraudio]

proc main() =
  ## Exercise the real streaming adapter with OpenAL Soft's null backend.
  doAssert getEnv("ALSOFT_DRIVERS") == "null", "Run with ALSOFT_DRIVERS=null."
  for rate in [0.0, -1.0, NaN, Inf]:
    var rejected = false
    try: discard audioFrequency(rate)
    except ValueError: rejected = true
    doAssert rejected
  doAssert audioFrequency(32768.4) == 32768
  let audio = newPlayerAudio(48000)
  defer: audio.close()
  let
    small = newSeq[int16](480 * 2)
    large = newSeq[int16](48000 * 2)
  audio.submit(small, 48000)
  doAssert audio.bufferedFrames() == 480
  sleep(80)
  audio.pump()
  doAssert audio.bufferedFrames() == 480
  audio.submit(small, 48000)
  audio.submit(small, 48000)
  let deadline = getMonoTime() + initDuration(seconds = 2)
  while audio.bufferedFrames() > 0:
    doAssert getMonoTime() < deadline
    sleep(10)
    audio.pump()
  audio.submit(small, 48000)
  doAssert audio.bufferedFrames() == 480
  audio.reset()
  doAssert audio.bufferedFrames() == 0
  for index in 0 ..< 40:
    audio.submit(large, 48000)
    doAssert audio.bufferedFrames() <= 48000 * MaxBufferedMs div 1000
  audio.reset()
  audio.submit(small, 48000)
  audio.submit(newSeq[int16](441 * 2), 44100)
  doAssert audio.bufferedFrames() == 441
  audio.reset()
  doAssert audio.bufferedFrames() == 0
  var rejected = false
  try: audio.submit(@[1'i16], 44100)
  except ValueError: rejected = true
  doAssert rejected
  audio.close()
  audio.close()
  let again = newPlayerAudio(32000)
  again.close()

main()
