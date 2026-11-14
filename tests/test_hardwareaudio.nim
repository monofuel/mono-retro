import
  std/[math, monotimes, os, times],
  openal,
  retro/[hardwareaudio, playermicrophone]

var
  starts, stops, closes, reads: int
  failRead = false
  pending = 0

proc capture(rate, bufferSamples: int): MicrophoneCapture =
  ## Supply signed PCM without accessing microphone hardware.
  doAssert rate == 44100 and bufferSamples == 4410
  MicrophoneCapture(
    start: (proc() = inc starts),
    stop: (proc() = inc stops),
    close: (proc() = inc closes),
    available: (proc(): int = pending),
    read: (proc(count: int): seq[uint8] =
      if failRead: raise newException(IOError, "fixture read failure")
      inc reads
      pending -= count
      result = newSeq[uint8](count * 2)
      for index in 0..<count:
        result[index * 2 + 1] = 0xc0))

proc unavailable(rate, bufferSamples: int): MicrophoneCapture =
  ## Simulate a capture device that cannot open.
  raise newException(IOError, "fixture missing microphone")

proc main() =
  ## Verify capture failures, actual null-backend playback position, and independent muting.
  doAssert getEnv("ALSOFT_DRIVERS") == "null", "Run with ALSOFT_DRIVERS=null."
  doAssert pcmPeak([]) == 0
  doAssert pcmPeak([0'u8, 0, 0, 0]) == 0
  doAssert pcmPeak([0'u8, 0x80]) == 1
  doAssert pcmPeak([0'u8, 0xc0]) == 0.5
  doAssert abs(0.5.decibels() + 6.0206) < 0.0001
  doAssert 0.0.meterFraction() == 0 and 1.0.meterFraction() == 1
  doAssert 0.01.meterFraction() > 0.3
  let muted = newHardwareAudio(muted = true, factory = capture)
  doAssert alcGetCurrentContext() == nil
  pending = 5000
  muted.play()
  muted.poll()
  doAssert reads == 2 and pending == 0
  doAssert muted.microphonePeak == 0.5 and muted.outputPeak == 0
  doAssert alcGetCurrentContext() == nil
  muted.poll()
  doAssert muted.microphonePeak == 0
  failRead = true
  pending = 1
  muted.poll()
  doAssert muted.microphoneError == "fixture read failure"
  muted.poll()
  muted.close()
  muted.close()
  doAssert starts == 1 and stops == 1 and closes == 1
  failRead = false
  pending = 4
  let boosted = newHardwareAudio(muted = true, factory = capture, gainDb = 12)
  boosted.poll()
  doAssert boosted.microphonePeak == 1
  boosted.close()
  let missing = newHardwareAudio(muted = true, factory = unavailable)
  doAssert missing.microphoneError == "fixture missing microphone"
  missing.poll()
  missing.close()
  let audio = newHardwareAudio(microphoneEnabled = false)
  defer: audio.close()
  doAssert alcGetCurrentContext() == nil
  audio.play()
  audio.play()
  doAssert audio.outputError.len == 0
  let deadline = getMonoTime() + initDuration(seconds = 5)
  var sawTone, sawGap: bool
  while audio.completed == 0:
    doAssert getMonoTime() < deadline
    audio.poll()
    if audio.outputPeak > 0.05: sawTone = true
    if sawTone and audio.outputPeak == 0 and audio.completed == 0: sawGap = true
    sleep(10)
  doAssert sawTone and sawGap
  doAssert audio.outputPeak == 0 and audio.microphonePeak == 0
  doAssert audio.completed == 1
  audio.close()
  audio.close()
  doAssert alcGetCurrentContext() == nil

main()
