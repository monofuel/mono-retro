import
  std/[atomics, dynlib, math, monotimes, os, times]

type
  AlsaApi = object
    library: LibHandle
    open: proc(pcm: ptr pointer, name: cstring, stream, mode: cint): cint {.cdecl, gcsafe.}
    setParams: proc(pcm: pointer, format, access: cint, channels, rate: cuint,
      resample: cint, latency: cuint): cint {.cdecl, gcsafe.}
    write: proc(pcm, data: pointer, frames: culong): clong {.cdecl, gcsafe.}
    recover: proc(pcm: pointer, code, silent: cint): cint {.cdecl, gcsafe.}
    drain: proc(pcm: pointer): cint {.cdecl, gcsafe.}
    close: proc(pcm: pointer): cint {.cdecl, gcsafe.}
    strerror: proc(code: cint): cstring {.cdecl, gcsafe.}
  AudioState = object
    api: AlsaApi
    device: array[256, char]
    requests, completed, recoveries: Atomic[int]
    stopping: Atomic[bool]
    error: Atomic[cint]
  AudioTest* = ref object
    device*: string
    state: ptr AudioState
    worker: Thread[ptr AudioState]
    reportedRecoveries: int
    completed*: int

const
  SampleRate* = 48000
  ToneSeconds* = 0.4
  GapSeconds* = 0.12
  SettleSeconds* = 0.25
  Amplitude = 0.06
  FadeSeconds = 0.025
  Channels = 2
  FrameBytes = Channels * sizeof(int16)
  WaveHeaderBytes = 44
  ChunkMilliseconds = 20
  ChunkFrames = SampleRate * ChunkMilliseconds div 1000
  PcmPlayback = 0.cint
  PcmSigned16LittleEndian = 2.cint
  PcmReadWriteInterleaved = 3.cint
  LatencyMicroseconds = 100000.cuint

proc loadAlsa(): AlsaApi =
  result.library = loadLib("libasound.so.2")
  if result.library == nil:
    raise newException(IOError, "Cannot load libasound.so.2")
  template bindSymbol(field: untyped, name: string) =
    result.field = cast[type(result.field)](symAddr(result.library, name))
    if result.field == nil:
      unloadLib(result.library)
      raise newException(IOError, "Missing ALSA symbol: " & name)
  bindSymbol(open, "snd_pcm_open")
  bindSymbol(setParams, "snd_pcm_set_params")
  bindSymbol(write, "snd_pcm_writei")
  bindSymbol(recover, "snd_pcm_recover")
  bindSymbol(drain, "snd_pcm_drain")
  bindSymbol(close, "snd_pcm_close")
  bindSymbol(strerror, "snd_strerror")

proc littleEndian(output: var string, value: uint32, bytes: int) =
  for index in 0 ..< bytes:
    output.add char((value shr (index * 8)) and 255)

proc toneWave*(): string =
  let
    framesPerTone = int(ToneSeconds * SampleRate)
    gapFrames = int(GapSeconds * SampleRate)
    settleFrames = int(SettleSeconds * SampleRate)
    frames = framesPerTone * 2 + gapFrames + settleFrames * 2
    bytes = frames * 4
  result = "RIFF"
  result.littleEndian(uint32(36 + bytes), 4)
  result.add "WAVEfmt "
  result.littleEndian(16, 4)
  result.littleEndian(1, 2)
  result.littleEndian(2, 2)
  result.littleEndian(SampleRate, 4)
  result.littleEndian(SampleRate * 4, 4)
  result.littleEndian(4, 2)
  result.littleEndian(16, 2)
  result.add "data"
  result.littleEndian(uint32(bytes), 4)
  for frame in 0 ..< frames:
    for channel in 0..1:
      let
        start = settleFrames + (if channel == 0: 0 else: framesPerTone + gapFrames)
        local = frame - start
      var sample = 0'i16
      if local >= 0 and local < framesPerTone:
        let
          frequency = if channel == 0: 440.0 else: 660.0
          fadeFrames = FadeSeconds * SampleRate
          envelope = min(1.0, min(float(local) / fadeFrames,
            float(framesPerTone - 1 - local) / fadeFrames))
          phase = 2 * PI * frequency * float(local) / SampleRate
        sample = int16(sin(phase) * Amplitude * envelope * float(high(int16)))
      result.littleEndian(uint32(cast[uint16](sample)), 2)

proc stream(state: ptr AudioState) {.thread.} =
  let api = state.api
  var pcm: pointer
  var code = api.open(addr pcm, cast[cstring](addr state.device[0]), PcmPlayback, 0)
  if code < 0:
    state.error.store(code)
    return
  defer:
    let closeCode = api.close(pcm)
    if closeCode < 0 and state.error.load() == 0:
      state.error.store(closeCode)
  code = api.setParams(pcm, PcmSigned16LittleEndian, PcmReadWriteInterleaved,
    Channels.cuint, SampleRate.cuint, 1, LatencyMicroseconds)
  if code < 0:
    state.error.store(code)
    return
  let
    wave = toneWave()
    waveFrames = (wave.len - WaveHeaderBytes) div FrameBytes
  var
    chunk: array[ChunkFrames * FrameBytes, char]
    position = waveFrames
    playing = 0
    deadline = getMonoTime()
  while not state.stopping.load():
    zeroMem(addr chunk[0], sizeof(chunk))
    if position == waveFrames and state.requests.load() > state.completed.load():
      position = 0
      playing = state.requests.load()
    if position < waveFrames:
      let frames = min(ChunkFrames, waveFrames - position)
      copyMem(addr chunk[0], unsafeAddr wave[WaveHeaderBytes + position * FrameBytes], frames * FrameBytes)
      position += frames
    var written = 0
    while written < ChunkFrames and not state.stopping.load():
      let count = api.write(pcm, addr chunk[written * FrameBytes], culong(ChunkFrames - written))
      if count < 0:
        code = api.recover(pcm, cint(count), 1)
        if code < 0:
          state.error.store(code)
          return
        discard state.recoveries.fetchAdd(1)
      elif count == 0:
        state.error.store(-5)
        return
      else:
        written += int(count)
    if written == ChunkFrames and position == waveFrames and playing > 0:
      state.completed.store(playing)
      playing = 0
    deadline = deadline + initDuration(milliseconds = ChunkMilliseconds)
    let remaining = int((deadline - getMonoTime()).inMilliseconds)
    if remaining > 0:
      sleep(remaining)
    elif remaining < -ChunkMilliseconds:
      deadline = getMonoTime()
  code = api.drain(pcm)
  if code < 0:
    state.error.store(code)

proc poll*(audio: AudioTest) =
  if audio.state == nil:
    return
  let
    code = audio.state.error.load()
    recoveries = audio.state.recoveries.load()
  if code < 0:
    let message = $audio.state.api.strerror(code)
    raise newException(IOError, "ALSA playback failed: " & message)
  if recoveries > audio.reportedRecoveries:
    stderr.writeLine("ALSA stream recoveries: " & $recoveries)
    audio.reportedRecoveries = recoveries
  audio.completed = audio.state.completed.load()

proc play*(audio: AudioTest) =
  audio.poll()
  if audio.state == nil:
    if audio.device.len >= sizeof(AudioState.device) or '\0' in audio.device:
      raise newException(ValueError, "Invalid ALSA device name")
    let api = loadAlsa()
    audio.state = cast[ptr AudioState](allocShared0(sizeof(AudioState)))
    audio.state.api = api
    for index, character in audio.device:
      audio.state.device[index] = character
    audio.state.requests.store(1)
    createThread(audio.worker, stream, audio.state)
  elif audio.state.requests.load() == audio.state.completed.load():
    discard audio.state.requests.fetchAdd(1)

proc close*(audio: AudioTest) =
  if audio.state != nil:
    audio.state.stopping.store(true)
    joinThread(audio.worker)
    defer:
      unloadLib(audio.state.api.library)
      deallocShared(audio.state)
      audio.state = nil
    audio.poll()
