import
  std/[math, monotimes, os, times],
  retro/[libretro, playeraudio]

const
  PartialHeadFrames = 4320 # Ninety milliseconds at the fixture's 48000 Hz.
  FollowingFrames = 1440 # Thirty milliseconds, making the whole sum 120 ms.
  PartialHeadWaitMs = 45
  PartialHeadAttempts = 8

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
  doAssert audio.underruns == 1
  audio.submit(small, 48000)
  doAssert audio.bufferedFrames() == 480
  audio.reset()
  audio.pump()
  doAssert audio.underruns == 1
  doAssert audio.bufferedFrames() == 0
  for index in 0 ..< 40:
    audio.submit(large, 48000)
    doAssert audio.bufferedFrames() <= 48000 * MaxBufferedMs div 1000
  doAssert audio.overruns > 0
  let
    head = newSeq[int16](PartialHeadFrames * 2)
    following = newSeq[int16](FollowingFrames * 2)
  var retainedBoth = false
  for attempt in 0 ..< PartialHeadAttempts:
    audio.reset()
    audio.submit(head, 48000)
    let before = audio.overruns
    sleep(PartialHeadWaitMs)
    audio.submit(following, 48000)
    if audio.bufferedFrames() == PartialHeadFrames + FollowingFrames:
      doAssert audio.overruns == before
      retainedBoth = true
      break
  doAssert retainedBoth, "Partial queued head must not cause a false overrun"
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
