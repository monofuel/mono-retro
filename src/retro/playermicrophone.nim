import
  slappy,
  ./microphone

type
  MicrophoneCapture* = ref object
    ## Capture operations run only on the core thread; factories may inject test input.
    start*, stop*, close*: proc() {.closure.}
    available*: proc(): int {.closure.}
    read*: proc(count: int): seq[uint8] {.closure.}
  MicrophoneFactory* = proc(rate, bufferSamples: int): MicrophoneCapture {.nimcall.}
  CapturedMicrophone = ref object
    capture: MicrophoneCapture
    rate: int
    enabled, failed: bool
  PlayerMicrophone* = ref object
    api*: MicrophoneInterface
    factory: MicrophoneFactory
    handles: seq[CapturedMicrophone]
    suspended: bool

const
  DefaultMicrophoneRate* = 44100
  MicrophoneBufferMs* = 100
  MaxMicrophoneRate = 192000
  MillisecondsPerSecond = 1000

var activeHost {.threadvar.}: PlayerMicrophone

proc slappyCapture(rate, bufferSamples: int): MicrophoneCapture =
  ## Open capture without creating or touching Slappy's playback context.
  let mic = newMicrophone(frequency = rate, channels = 1, bits = 16,
    bufferSize = bufferSamples)
  result = MicrophoneCapture(
    start: proc() = mic.start(),
    stop: proc() = mic.stop(),
    close: proc() = mic.close(),
    available: proc(): int = mic.samplesAvailable(),
    read: proc(count: int): seq[uint8] = mic.read(count))

proc find(handle: MicrophoneHandle): CapturedMicrophone =
  ## Validate opaque handles before dereferencing any caller-provided address.
  if handle == nil or activeHost == nil: return
  for mic in activeHost.handles:
    if cast[MicrophoneHandle](mic) == handle: return mic

proc report(mic: CapturedMicrophone, error: ref CatchableError) =
  ## Report once and substitute silence for a failed capture device thereafter.
  if not mic.failed:
    stderr.writeLine("Microphone unavailable; using silence: " & error.msg)
    try: mic.capture.stop()
    except CatchableError: discard
  mic.failed = true

proc discardPending(mic: CapturedMicrophone) =
  ## Drain stale PCM in bounded chunks without requesting unavailable samples.
  let count = mic.capture.available()
  if count < 0: raise newException(IOError, "Invalid microphone sample count")
  var remaining = count
  let chunk = max(1, mic.rate * MicrophoneBufferMs div MillisecondsPerSecond)
  while remaining > 0:
    let size = min(remaining, chunk)
    discard mic.capture.read(size)
    remaining -= size

proc openMic(params: ptr ConstMicrophoneParams): MicrophoneHandle {.cdecl.} =
  ## Create an initially inactive capture handle, returning nil on device failure.
  if activeHost == nil: return nil
  let requestedRate = if params == nil or params.rate == 0:
    DefaultMicrophoneRate.cuint else: params.rate
  if requestedRate > MaxMicrophoneRate.cuint: return nil
  let rate = int(requestedRate)
  var capture: MicrophoneCapture
  try:
    capture = activeHost.factory(rate,
      max(1, rate * MicrophoneBufferMs div MillisecondsPerSecond))
    if capture == nil: raise newException(IOError, "No capture device")
    let mic = CapturedMicrophone(capture: capture, rate: rate)
    activeHost.handles.add(mic)
    return cast[MicrophoneHandle](mic)
  except CatchableError as error:
    stderr.writeLine("Microphone unavailable; using silence: " & error.msg)
    if capture != nil:
      try: capture.close()
      except CatchableError: discard

proc closeMic(handle: MicrophoneHandle) {.cdecl.} =
  ## Release a known handle; nil and already-closed handles are harmless.
  let mic = find(handle)
  if mic == nil: return
  try:
    if mic.enabled and not activeHost.suspended:
      try: mic.capture.stop()
      except CatchableError as error: mic.report(error)
    mic.capture.close()
  except CatchableError as error: mic.report(error)
  for index in 0 ..< activeHost.handles.len:
    if activeHost.handles[index] == mic:
      activeHost.handles.delete(index)
      break

proc getParams(handle: ConstMicrophoneHandle, params: ptr MicrophoneParams): bool {.cdecl.} =
  ## Report the fixed capture rate negotiated when this handle was opened.
  let mic = find(cast[MicrophoneHandle](handle))
  if mic == nil or params == nil: return false
  params.rate = mic.rate.cuint
  true

proc setState(handle: MicrophoneHandle, enabled: bool): bool {.cdecl.} =
  ## Keep the core's requested state separate from a frontend pause.
  let mic = find(handle)
  if mic == nil: return false
  if mic.enabled == enabled: return true
  mic.enabled = enabled
  if mic.failed or activeHost.suspended: return true
  try:
    if enabled:
      mic.discardPending()
      mic.capture.start()
    else:
      mic.capture.stop()
      mic.discardPending()
    return true
  except CatchableError as error:
    mic.report(error)
    return true

proc getState(handle: ConstMicrophoneHandle): bool {.cdecl.} =
  ## Return the logical state even when frontend capture is suspended.
  let mic = find(cast[MicrophoneHandle](handle))
  mic != nil and mic.enabled

proc readMic(handle: MicrophoneHandle, samples: ptr int16, count: csize_t): cint {.cdecl.} =
  ## Deliver current mono PCM, padding underflow without blocking the core.
  let mic = find(handle)
  if mic == nil or not mic.enabled or activeHost.suspended: return -1
  if count > high(cint).csize_t or count > (high(int) div sizeof(int16)).csize_t or
      (count > 0 and samples == nil): return -1
  if count == 0: return 0
  zeroMem(samples, int(count) * sizeof(int16))
  result = cint(count)
  if mic.failed: return
  try:
    let available = mic.capture.available()
    if available < 0: raise newException(IOError, "Invalid microphone sample count")
    var stale = max(0, available - int(count))
    let chunk = max(1, mic.rate * MicrophoneBufferMs div MillisecondsPerSecond)
    while stale > 0:
      let size = min(stale, chunk)
      discard mic.capture.read(size)
      stale -= size
    let size = min(available, int(count))
    if size > 0:
      let data = mic.capture.read(size)
      if data.len != size * sizeof(int16):
        raise newException(IOError, "Incomplete microphone PCM")
      copyMem(samples, unsafeAddr data[0], data.len)
  except CatchableError as error:
    mic.report(error)

proc newPlayerMicrophone*(factory: MicrophoneFactory = nil): PlayerMicrophone =
  ## Install one thread-local host without opening hardware until a core requests it.
  if activeHost != nil: raise newException(ValueError, "Microphone host already active")
  result = PlayerMicrophone(factory: (if factory == nil: slappyCapture else: factory))
  result.api = MicrophoneInterface(version: MicrophoneVersion, open: openMic,
    close: closeMic, getParams: getParams, setState: setState, getState: getState, read: readMic)
  activeHost = result

proc suspend*(host: PlayerMicrophone) =
  ## Stop capture while paused and discard pre-pause audio.
  if host == nil or host.suspended: return
  host.suspended = true
  for mic in host.handles:
    if mic.enabled and not mic.failed:
      try:
        mic.capture.stop()
        mic.discardPending()
      except CatchableError as error: mic.report(error)

proc resume*(host: PlayerMicrophone) =
  ## Restart requested capture before advancing the next gameplay frame.
  if host == nil or not host.suspended: return
  host.suspended = false
  for mic in host.handles:
    if mic.enabled and not mic.failed:
      try:
        mic.discardPending()
        mic.capture.start()
      except CatchableError as error: mic.report(error)

proc reset*(host: PlayerMicrophone) =
  ## Discard captured audio across state restoration without changing logical state.
  if host == nil: return
  let wasSuspended = host.suspended
  host.suspend()
  if not wasSuspended: host.resume()

proc close*(host: PlayerMicrophone) =
  ## Close handles left behind by a core, after unloading that core.
  if host == nil or activeHost != host: return
  while host.handles.len > 0:
    closeMic(cast[MicrophoneHandle](host.handles[^1]))
  activeHost = nil
