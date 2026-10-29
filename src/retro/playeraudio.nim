import
  openal, slappy,
  ./libretro

type
  PlayerAudio* = ref object
    stream: StreamingSource
    frequency: int
    initialized: bool
    started: bool
    underruns*, overruns*: int
    pending: seq[uint8]
    chunks: seq[int]

const
  Channels = 2
  FrameBytes = Channels * sizeof(int16)
  PrebufferMs* = 30
  MaxBufferedMs* = 100
  MillisecondsPerSecond = 1000

proc checkAudio() =
  ## Report errors from the underlying OpenAL operations Slappy performs.
  let error = alGetError()
  if error != AL_NO_ERROR:
    raise newException(IOError, "OpenAL playback error: " & $error)

proc close*(audio: PlayerAudio) =
  ## Release queued buffers and the source before destroying its context.
  if audio == nil or not audio.initialized: return
  try:
    if audio.stream != nil:
      audio.stream.close()
      checkAudio()
  finally:
    audio.stream = nil
    audio.initialized = false
    try:
      if not alcMakeContextCurrent(nil):
        raise newException(IOError, "Failed to detach the OpenAL context")
    finally:
      slappyClose()

proc newPlayerAudio*(sampleRate: float): PlayerAudio =
  ## Open Slappy's selected audio device for one stereo PCM stream.
  result = PlayerAudio(frequency: audioFrequency(sampleRate))
  slappyInit()
  result.initialized = true
  try:
    result.stream = newStreamingSource(result.frequency, Channels, 16)
    checkAudio()
  except:
    result.close()
    raise

proc pump*(audio: PlayerAudio) =
  ## Reclaim finished buffers and their corresponding duration records.
  audio.stream.pump()
  if audio.started and not audio.stream.playing():
    inc audio.underruns
    audio.started = false
  checkAudio()
  let processed = audio.chunks.len - audio.stream.queuedLen()
  if processed > 0:
    audio.chunks = audio.chunks[processed .. ^1]

proc bufferedFrames*(audio: PlayerAudio): int =
  ## Return an upper bound on queued stereo frames, including pending PCM.
  result = audio.pending.len div FrameBytes
  for frames in audio.chunks: result += frames

proc reset*(audio: PlayerAudio) =
  ## Stop playback and forget old audio before pausing or priming again.
  audio.stream.flush()
  checkAudio()
  audio.pending.setLen(0)
  audio.chunks.setLen(0)
  audio.started = false

proc submit*(audio: PlayerAudio, samples: seq[int16], sampleRate: float) =
  ## Queue one frame's PCM, bounding latency and priming after underruns.
  if samples.len mod Channels != 0:
    raise newException(ValueError, "Audio samples must contain complete stereo frames")
  let frequency = audioFrequency(sampleRate)
  if frequency != audio.frequency:
    audio.reset()
    audio.stream.close()
    checkAudio()
    audio.stream = nil
    audio.frequency = frequency
    audio.stream = newStreamingSource(frequency, Channels, 16)
    checkAudio()
  audio.pump()
  if samples.len == 0: return
  let
    maximum = max(1, frequency * MaxBufferedMs div MillisecondsPerSecond)
    frames = min(samples.len div Channels, maximum)
    first = samples.len - frames * Channels
  if audio.bufferedFrames() + frames > maximum:
    inc audio.overruns
    audio.reset()
  var bytes = newSeq[uint8](frames * FrameBytes)
  copyMem(addr bytes[0], unsafeAddr samples[first], bytes.len)
  if audio.chunks.len == 0:
    audio.pending.add(bytes)
    if audio.pending.len div FrameBytes <
        (frequency * PrebufferMs + MillisecondsPerSecond - 1) div MillisecondsPerSecond:
      return
    bytes = move(audio.pending)
  audio.stream.queueData(bytes)
  audio.started = true
  audio.chunks.add(bytes.len div FrameBytes)
  checkAudio()
