import
  openal, slappy,
  ./[libretro, playbackcontext]

type
  PlayerAudio* = ref object
    stream: StreamingSource
    frequency, prebufferMs: int
    initialized: bool
    started: bool
    underruns*, overruns*: int
    pending: seq[uint8]
    chunks: seq[int]
    playback: PlaybackContext
    headphones: bool
    connectionProbe: proc(): bool {.closure.}
    error*: string

const
  Channels = 2
  FrameBytes = Channels * sizeof(int16)
  PrebufferMs* = 30
  MaxBufferedMs* = 100
  MillisecondsPerSecond = 1000
  AlcConnected = 0x313.cint

proc checkAudio() =
  ## Report errors from the underlying OpenAL operations Slappy performs.
  let error = alGetError()
  if error != AL_NO_ERROR:
    raise newException(IOError, "OpenAL playback error: " & $error)

proc checkConnection(audio: PlayerAudio) =
  ## Detect a lost headphone PCM without reconnecting or changing the output.
  if not audio.headphones: return
  if audio.connectionProbe != nil:
    if not audio.connectionProbe():
      raise newException(IOError, "Headphones disconnected; audio is muted until the next launch")
  else:
    let device = alcGetContextsDevice(alcGetCurrentContext())
    var connected: ALCint
    alcGetIntegerv(device, AlcConnected, 1, addr connected)
    let error = alcGetError(device)
    if error != ALC_NO_ERROR:
      raise newException(IOError, "Cannot check headphone connection: " & $error)
    if connected == ALC_FALSE:
      raise newException(IOError, "Headphones disconnected; audio is muted until the next launch")

proc failPlayback(audio: PlayerAudio, message: string) =
  ## Stop a failed routed output once while allowing the game to keep running.
  if not audio.headphones:
    raise newException(IOError, message)
  if audio.error.len > 0: return
  audio.error = message
  audio.pending.setLen(0)
  audio.chunks.setLen(0)
  audio.started = false
  alListenerf(AL_GAIN, 0)
  if audio.stream != nil: audio.stream.stop()
  let muteError = alGetError()
  if muteError != AL_NO_ERROR:
    audio.error.add "; OpenAL stop error: " & $muteError
  stderr.writeLine("Audio output unavailable: " & audio.error)

proc close*(audio: PlayerAudio) =
  ## Release queued buffers and the source before destroying its context.
  if audio == nil or not audio.initialized: return
  try:
    if audio.stream != nil:
      audio.stream.close()
      if audio.error.len == 0: checkAudio()
  finally:
    audio.stream = nil
    audio.initialized = false
    if audio.playback != nil:
      audio.playback.close()
    else:
      try:
        if not alcMakeContextCurrent(nil):
          raise newException(IOError, "Failed to detach the OpenAL context")
      finally:
        slappyClose()

proc newPlayerAudio*(sampleRate: float, prebufferMs = PrebufferMs, headphones = false,
    connectionProbe: proc(): bool {.closure.} = nil): PlayerAudio =
  ## Open stereo PCM output with the requested priming duration in milliseconds.
  if prebufferMs notin 1..MaxBufferedMs:
    raise newException(ValueError, "Audio prebuffer must be between 1 and " & $MaxBufferedMs & " ms")
  result = PlayerAudio(frequency: audioFrequency(sampleRate), prebufferMs: prebufferMs,
    headphones: headphones, connectionProbe: connectionProbe)
  if headphones: result.playback = openPlaybackContext()
  else: slappyInit()
  result.initialized = true
  try:
    if headphones and connectionProbe == nil and
        not alcIsExtensionPresent(alcGetContextsDevice(alcGetCurrentContext()), "ALC_EXT_disconnect"):
      raise newException(IOError, "OpenAL cannot monitor headphone disconnection")
    result.stream = newStreamingSource(result.frequency, Channels, 16)
    checkAudio()
  except:
    result.close()
    raise

proc pumpOutput(audio: PlayerAudio) =
  ## Reclaim finished buffers and their corresponding duration records.
  audio.checkConnection()
  audio.stream.pump()
  if audio.started and not audio.stream.playing():
    inc audio.underruns
    audio.started = false
  checkAudio()
  let processed = audio.chunks.len - audio.stream.queuedLen()
  if processed > 0:
    audio.chunks = audio.chunks[processed .. ^1]

proc pump*(audio: PlayerAudio) =
  ## Reclaim played PCM or permanently mute a failed headphone output.
  if audio.error.len > 0: return
  try: audio.pumpOutput()
  except CatchableError as error: audio.failPlayback(error.msg)

proc bufferedFrames*(audio: PlayerAudio): int =
  ## Return an upper bound on queued stereo frames, including pending PCM.
  result = audio.pending.len div FrameBytes
  for frames in audio.chunks: result += frames

proc resetOutput(audio: PlayerAudio) =
  ## Stop playback and forget old audio before pausing or priming again.
  audio.stream.flush()
  checkAudio()
  audio.pending.setLen(0)
  audio.chunks.setLen(0)
  audio.started = false

proc reset*(audio: PlayerAudio) =
  ## Reset healthy playback without reopening a disconnected headphone device.
  if audio.error.len > 0: return
  try: audio.resetOutput()
  except CatchableError as error: audio.failPlayback(error.msg)

proc submitOutput(audio: PlayerAudio, samples: seq[int16], sampleRate: float) =
  ## Queue one frame's PCM, bounding latency and priming after underruns.
  if samples.len mod Channels != 0:
    raise newException(ValueError, "Audio samples must contain complete stereo frames")
  let frequency = audioFrequency(sampleRate)
  if frequency != audio.frequency:
    audio.resetOutput()
    audio.stream.close()
    checkAudio()
    audio.stream = nil
    audio.frequency = frequency
    audio.stream = newStreamingSource(frequency, Channels, 16)
    checkAudio()
  audio.pumpOutput()
  if samples.len == 0: return
  let
    maximum = max(1, frequency * MaxBufferedMs div MillisecondsPerSecond)
    frames = min(samples.len div Channels, maximum)
    first = samples.len - frames * Channels
    buffered = audio.bufferedFrames()
  if buffered + frames > maximum:
    let consumed = int(audio.stream.sampleOffset())
    checkAudio()
    if consumed < 0 or consumed > buffered - audio.pending.len div FrameBytes:
      raise newException(IOError, "OpenAL sample offset is outside queued PCM")
    if buffered - consumed + frames > maximum:
      inc audio.overruns
      audio.resetOutput()
  var bytes = newSeq[uint8](frames * FrameBytes)
  copyMem(addr bytes[0], unsafeAddr samples[first], bytes.len)
  if audio.chunks.len == 0:
    audio.pending.add(bytes)
    let minimum = min(maximum,
      (frequency * audio.prebufferMs + MillisecondsPerSecond - 1) div MillisecondsPerSecond)
    if audio.pending.len div FrameBytes < minimum:
      return
    bytes = move(audio.pending)
  audio.stream.queueData(bytes)
  audio.started = true
  audio.chunks.add(bytes.len div FrameBytes)
  checkAudio()

proc submit*(audio: PlayerAudio, samples: seq[int16], sampleRate: float) =
  ## Queue game PCM until a headphone failure, then discard it without retrying.
  if samples.len mod Channels != 0:
    raise newException(ValueError, "Audio samples must contain complete stereo frames")
  discard audioFrequency(sampleRate)
  if audio.error.len > 0: return
  try: audio.submitOutput(samples, sampleRate)
  except CatchableError as error: audio.failPlayback(error.msg)
