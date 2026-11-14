import
  std/math,
  openal, slappy,
  ./[audio, playermicrophone]

type
  HardwareAudio* = ref object
    capture: MicrophoneCapture
    stream: StreamingSource
    initialized, playing: bool
    tone: seq[uint8]
    muted*, microphoneEnabled*: bool
    outputPeak*, microphonePeak*: float
    outputError*, microphoneError*: string
    completed*: int
    gain: float

const
  MeterFloorDb* = -60.0
  FullScale = 32768.0
  WaveHeaderBytes = 44
  StereoFrameBytes = 4
  MeterWindowMs = 80

proc pcmPeak*(bytes: openArray[uint8]): float =
  ## Return the full-scale peak of little-endian signed 16-bit PCM.
  if bytes.len mod sizeof(int16) != 0:
    raise newException(ValueError, "Expected complete signed 16-bit samples")
  for index in countup(0, bytes.len - 2, 2):
    let
      word = uint16(bytes[index]) or (uint16(bytes[index + 1]) shl 8)
      sample = int(cast[int16](word))
    result = max(result, abs(sample).float / FullScale)

proc decibels*(peak: float): float =
  ## Express a normalized peak in dBFS, clamped to the meter floor.
  if peak <= 0: MeterFloorDb else: max(MeterFloorDb, 20 * log10(min(1.0, peak)))

proc meterFraction*(peak: float): float =
  ## Map the audible range from the meter floor to full scale onto a bar.
  (peak.decibels() - MeterFloorDb) / -MeterFloorDb

proc checkOutput() =
  ## Surface OpenAL playback failures instead of displaying a false output level.
  let error = alGetError()
  if error != AL_NO_ERROR:
    raise newException(IOError, "OpenAL playback error: " & $error)

proc close*(audio: HardwareAudio) =
  ## Release capture and playback independently, including partial initialization.
  if audio == nil: return
  try:
    if audio.capture != nil:
      let capture = audio.capture
      audio.capture = nil
      try: capture.stop()
      finally: capture.close()
  finally:
    if audio.initialized:
      audio.initialized = false
      try:
        if audio.stream != nil:
          audio.stream.close()
          audio.stream = nil
      finally:
        discard alcMakeContextCurrent(nil)
        slappyClose()

proc newHardwareAudio*(muted = false, microphoneEnabled = true,
    factory: MicrophoneFactory = nil, gainDb = 0): HardwareAudio =
  ## Start live capture; playback opens only on a requested tone and never monitors the mic.
  result = HardwareAudio(muted: muted, microphoneEnabled: microphoneEnabled,
    gain: microphoneGainFactor(gainDb))
  if microphoneEnabled:
    try:
      let createCapture = if factory == nil: slappyCapture else: factory
      result.capture = createCapture(DefaultMicrophoneRate,
        DefaultMicrophoneRate * MicrophoneBufferMs div 1000)
      if result.capture == nil: raise newException(IOError, "No capture device")
      result.capture.start()
    except CatchableError as error:
      result.microphoneError = error.msg
      stderr.writeLine("Microphone unavailable: " & error.msg)
      if result.capture != nil:
        try: result.capture.close()
        except CatchableError: discard
        result.capture = nil

proc play*(audio: HardwareAudio) =
  ## Play one stereo test tone through Slappy, ignoring presses during playback.
  if audio == nil or audio.muted or audio.playing or audio.outputError.len > 0: return
  try:
    if not audio.initialized:
      slappyInit()
      audio.initialized = true
      audio.stream = newStreamingSource(SampleRate, 2, 16)
      checkOutput()
      let wave = toneWave()
      audio.tone = newSeq[uint8](wave.len - WaveHeaderBytes)
      copyMem(addr audio.tone[0], unsafeAddr wave[WaveHeaderBytes], audio.tone.len)
    audio.stream.flush()
    audio.stream.queueData(audio.tone)
    checkOutput()
    audio.playing = true
  except CatchableError as error:
    audio.outputError = error.msg
    audio.outputPeak = 0
    stderr.writeLine("Speaker output unavailable: " & error.msg)

proc poll*(audio: HardwareAudio) =
  ## Measure recent output PCM and drain live microphone PCM without saving or playing it.
  if audio == nil: return
  audio.outputPeak = 0
  audio.microphonePeak = 0
  if audio.playing and audio.outputError.len == 0:
    try:
      if audio.stream.playing():
        let
          last = clamp(int(audio.stream.sampleOffset()) * StereoFrameBytes, 0, audio.tone.len)
          first = max(0, last - SampleRate * MeterWindowMs div 1000 * StereoFrameBytes)
        if last > first: audio.outputPeak = pcmPeak(audio.tone.toOpenArray(first, last - 1))
      else:
        audio.playing = false
        inc audio.completed
        audio.stream.pump()
      checkOutput()
    except CatchableError as error:
      audio.outputError = error.msg
      audio.outputPeak = 0
      stderr.writeLine("Speaker output unavailable: " & error.msg)
  if audio.capture != nil:
    try:
      var remaining = audio.capture.available()
      if remaining < 0: raise newException(IOError, "Invalid microphone sample count")
      while remaining > 0:
        let count = min(remaining, DefaultMicrophoneRate * MicrophoneBufferMs div 1000)
        var data = audio.capture.read(count)
        if data.len != count * sizeof(int16):
          raise newException(IOError, "Incomplete microphone PCM")
        data.applyMicrophoneGain(audio.gain)
        audio.microphonePeak = max(audio.microphonePeak, pcmPeak(data))
        remaining -= count
    except CatchableError as error:
      audio.microphoneError = error.msg
      audio.microphonePeak = 0
      stderr.writeLine("Microphone unavailable: " & error.msg)
      let capture = audio.capture
      audio.capture = nil
      try: capture.stop()
      except CatchableError: discard
      try: capture.close()
      except CatchableError: discard
