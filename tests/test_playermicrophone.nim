import
  std/[json, math, os, strutils, tempfiles],
  retro/[libretro, microphone, playercapture, playermicrophone, playerworker]

type
  SyntheticCapture = ref object
    owner, rate, bufferSamples, starts, stops, closes: int
    running, continuous, failRead: bool
    samples: seq[int16]

var
  lastCapture {.threadvar.}: SyntheticCapture
  toneSilent {.threadvar.}: bool
  toneReads {.threadvar.}: int

proc toneCapture(rate, bufferSamples: int): MicrophoneCapture =
  ## Supply a synthetic 440 Hz tone or silence for the real core's recording ROM.
  var
    running = false
    phase = 0
  let
    silent = toneSilent
    actualRate = if rate <= DefaultMicrophoneRate: DefaultMicrophoneRate else: 48000
  result = MicrophoneCapture(
    rate: actualRate,
    start: proc() = running = true,
    stop: proc() = running = false,
    close: proc() = running = false,
    available: proc(): int = (if running: 735 else: 0),
    read: (proc(count: int): seq[uint8] =
      inc toneReads
      var samples = newSeq[int16](count)
      for sample in samples.mitems:
        if not silent: sample = int16(sin(2 * PI * 440 * phase.float / actualRate.float) * 30000)
        inc phase
      result = newSeq[uint8](count * sizeof(int16))
      copyMem(addr result[0], addr samples[0], result.len)))

proc event(state: SyntheticCapture, name: string) =
  ## Assert thread ownership and retain worker lifecycle evidence.
  doAssert state.owner == getThreadId()
  let path = getEnv("MONO_RETRO_MIC_TRACE")
  if path.len > 0:
    let file = open(path, fmAppend)
    try: file.writeLine(name)
    finally: file.close()

proc syntheticCapture(rate, bufferSamples: int): MicrophoneCapture =
  ## Provide signed PCM without opening capture or playback hardware.
  let state = SyntheticCapture(owner: getThreadId(), rate: rate,
    bufferSamples: bufferSamples, continuous: true)
  lastCapture = state
  state.event("open")
  result = MicrophoneCapture(
    start: (proc() =
      state.event("start")
      inc state.starts
      state.running = true),
    stop: (proc() =
      state.event("stop")
      inc state.stops
      state.running = false),
    close: (proc() =
      state.event("close")
      inc state.closes),
    available: (proc(): int =
      state.event("available")
      if state.continuous: (if state.running: 4 else: 0) else: state.samples.len),
    read: (proc(count: int): seq[uint8] =
      state.event("read")
      if state.failRead: raise newException(IOError, "synthetic capture failure")
      let data = if state.continuous: @[-123'i16, 321, -456, 789] else: state.samples
      doAssert count > 0 and count <= data.len
      result = newSeq[uint8](count * sizeof(int16))
      copyMem(addr result[0], unsafeAddr data[0], result.len)
      if not state.continuous: state.samples = state.samples[count .. ^1]))

proc unavailableCapture(rate, bufferSamples: int): MicrophoneCapture =
  ## Simulate a system with no usable microphone.
  raise newException(IOError, "synthetic missing device")

proc negotiatedCapture(rate, bufferSamples: int): MicrophoneCapture =
  ## Model a standard hardware rate differing from the core's requested rate.
  doAssert rate == 47605 and bufferSamples == 4760
  result = syntheticCapture(48000, 4800)
  result.rate = 48000

proc testNegotiatedRate() =
  ## Report the actual hardware rate so the core can resample its microphone input.
  let host = newPlayerMicrophone(negotiatedCapture)
  defer: host.close()
  var params = MicrophoneParams(rate: 47605)
  let handle = host.api.open(addr params)
  doAssert handle != nil
  doAssert host.api.getParams(handle, addr params)
  doAssert params.rate == 48000
  doAssert host.api.setState(handle, true)
  var samples: array[4, int16]
  doAssert host.api.read(handle, addr samples[0], samples.len.csize_t) == samples.len
  doAssert samples == [-123'i16, 321, -456, 789]
  host.api.close(handle)
  doAssert lastCapture.closes == 1

proc testAdapter() =
  ## Exercise callback contracts, current PCM, pause handling and device failure.
  let host = newPlayerMicrophone(syntheticCapture)
  defer: host.close()
  let api = host.api
  var params = MicrophoneParams(rate: 0)
  let defaultHandle = api.open(addr params)
  doAssert defaultHandle != nil
  doAssert api.getParams(defaultHandle, addr params) and params.rate == 44100
  api.close(defaultHandle)
  params.rate = 192001
  doAssert api.open(addr params) == nil
  let handle = api.open(nil)
  doAssert handle != nil
  let state = lastCapture
  state.continuous = false
  doAssert state.rate == 44100 and state.bufferSamples == 4410
  doAssert not api.getState(handle)
  doAssert api.getParams(handle, addr params) and params.rate == 44100
  doAssert not api.getParams(handle, nil)
  var output: array[6, int16]
  doAssert api.read(handle, addr output[0], 6) == -1
  doAssert api.setState(handle, true)
  doAssert state.starts == 1
  doAssert api.setState(handle, true) and state.starts == 1
  state.samples = @[low(int16), -1'i16, 0, high(int16)]
  doAssert api.read(handle, addr output[0], 6) == 6
  doAssert output == [low(int16), -1'i16, 0, high(int16), 0, 0]
  doAssert api.read(handle, nil, 0) == 0
  doAssert api.read(handle, nil, 1) == -1
  doAssert api.read(handle, addr output[0], high(csize_t)) == -1
  state.samples = @[1'i16, 2, 3, 4, 5, 6, 7, 8]
  doAssert api.read(handle, addr output[0], 6) == 6
  doAssert output == [3'i16, 4, 5, 6, 7, 8]
  state.samples = @[9'i16]
  host.suspend()
  doAssert not state.running and state.samples.len == 0
  doAssert api.getState(handle)
  doAssert api.read(handle, addr output[0], 6) == -1
  state.samples = @[10'i16]
  host.resume()
  doAssert state.running and state.samples.len == 0
  state.samples = @[11'i16]
  host.reset()
  doAssert state.running and state.samples.len == 0
  doAssert api.setState(handle, false)
  host.suspend()
  doAssert api.setState(handle, true) and not state.running
  host.resume()
  doAssert state.running
  state.samples = @[12'i16]
  state.failRead = true
  doAssert api.read(handle, addr output[0], 6) == 6
  doAssert output == default(array[6, int16])
  doAssert not state.running
  state.failRead = false
  doAssert api.read(handle, addr output[0], 6) == 6
  doAssert output == default(array[6, int16])
  api.close(handle)
  api.close(handle)
  api.close(nil)
  doAssert state.closes == 1
  doAssert not api.getState(handle)
  doAssert not api.setState(handle, true)
  doAssert api.read(handle, addr output[0], 1) == -1
  params.rate = 32000
  discard api.open(addr params)
  let remaining = lastCapture
  doAssert remaining.rate == 32000
  host.close()
  host.close()
  doAssert remaining.closes == 1
  let unavailable = newPlayerMicrophone(unavailableCapture)
  doAssert unavailable.api.open(nil) == nil
  unavailable.close()

proc testInputGain() =
  ## Boost microphone PCM without wrapping clipped positive or negative samples.
  let host = newPlayerMicrophone(syntheticCapture, gainDb = 12)
  defer: host.close()
  let handle = host.api.open(nil)
  doAssert handle != nil
  let state = lastCapture
  state.continuous = false
  doAssert host.api.setState(handle, true)
  state.samples = @[-20000'i16, 20000]
  var output: array[4, int16]
  doAssert host.api.read(handle, addr output[0], output.len.csize_t) == output.len
  doAssert output == [low(int16), high(int16), 0, 0]

proc testWorker() =
  ## Cover C ABI negotiation, worker ownership, recording policy and cleanup.
  let
    directory = createTempDir("player-microphone-", "")
    trace = directory / "core-trace"
    micTrace = directory / "microphone-trace"
    rom = directory / "fixture.test"
    core = absolutePath("build/player-fixture.so")
  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  putEnv("MONO_RETRO_MIC_TRACE", micTrace)
  defer:
    delEnv("MONO_RETRO_FIXTURE_TRACE")
    delEnv("MONO_RETRO_MIC_TRACE")
    removeDir(directory)
  for mode in ["m", "l"]:
    writeFile(rom, mode)
    let worker = openCoreWorker(core, rom, directory / mode,
      microphoneEnabled = true, microphoneFactory = syntheticCapture,
      captureDirectory = directory / "captures")
    let captureDirectory = worker.captureDirectory
    worker.step(0)
    worker.pause()
    worker.step(0)
    worker.capture(withState = true)
    let state = worker.exportState()
    worker.importStateData(state, "microphone reset")
    worker.step(0)
    worker.close()
    doAssert readFile(trace).contains("mic_supported=1\n")
    doAssert readFile(trace).contains("mic_always=1\nmic_input=1\n")
    doAssert readFile(trace).contains("mic_sample=65413\n")
    var pngs = 0
    for path in walkFiles(captureDirectory / "*.png"):
      inc pngs
      doAssert readFile(path).contains("mrSt")
      doAssert parseJson(readFile(path.changeFileExt("json")))["replay"].getStr == ""
    doAssert pngs == 2
    for path in walkFiles(captureDirectory / "segment_*.json"):
      var rejected = false
      try: discard readReplay(path)
      except IOError as error: rejected = error.msg.contains("microphone")
      doAssert rejected
  let events = readFile(micTrace)
  doAssert events.count("open\n") == 2 and events.count("close\n") == 2
  doAssert events.count("start\n") >= 6 and events.count("stop\n") >= 6
  writeFile(rom, "f")
  var rejected = false
  try:
    discard openCoreWorker(core, rom, directory / "failure",
      microphoneEnabled = true, microphoneFactory = syntheticCapture)
  except IOError: rejected = true
  doAssert rejected
  doAssert readFile(micTrace).count("close\n") == 3
  writeFile(rom, "m")
  writeFile(trace, "")
  let off = openCoreWorker(core, rom, directory / "off",
    microphoneFactory = syntheticCapture)
  off.step(0)
  off.close()
  doAssert readFile(trace).contains("mic_supported=0\n")
  doAssert readFile(micTrace).count("open\n") == 3
  let missing = openCoreWorker(core, rom, directory / "missing",
    microphoneEnabled = true, microphoneFactory = unavailableCapture)
  missing.step(0)
  missing.close()
  writeFile(rom, "D")
  let lazy = openCoreWorker(core, rom, directory / "lazy",
    microphoneEnabled = true, microphoneFactory = syntheticCapture,
    captureDirectory = directory / "captures")
  let lazyDirectory = lazy.captureDirectory
  lazy.step(0)
  lazy.close()
  doAssert readFile(micTrace).count("open\n") == 3
  doAssert readReplay(lazyDirectory / "segment_0001.json").inputs.len == 1
  writeFile(rom, "m")
  let old = openCoreWorker(core, rom, directory / "old",
    options = @[("melonds_mic_input", "silence")],
    captureDirectory = directory / "captures")
  let replayPath = old.captureDirectory / "segment_0001.json"
  old.step(0)
  old.close()
  let replayed = openCoreWorker(core, rom, directory / "replay",
    replayPath = replayPath, microphoneEnabled = true, microphoneFactory = syntheticCapture)
  replayed.step(0)
  doAssert replayed.shutdown
  replayed.close()
  doAssert readFile(micTrace).count("open\n") == 3
  rejected = false
  try:
    discard openCoreWorker(core, rom, directory / "mismatched-replay", replayPath = replayPath,
      options = @[("fixture_option", "second")], microphoneEnabled = true,
      microphoneFactory = syntheticCapture)
  except IOError as error: rejected = error.msg.contains("same core options")
  doAssert rejected

proc testMelonDs(core, rom: string) =
  ## Require the real core to record supplied microphone PCM and play it back.
  let directory = createTempDir("melonds-microphone-", "")
  defer: removeDir(directory)
  var outputs: array[2, seq[int16]]
  for run in 0 .. 1:
    toneSilent = run == 1
    toneReads = 0
    let host = newPlayerMicrophone(toneCapture)
    try:
      let session = openCore(core, rom, directory / $run, captureAudio = true,
        microphoneInterface = addr host.api, defaultOptions = @[
          ("melonds_mic_input", "microphone"), ("melonds_mic_input_active", "always")])
      try:
        doAssert session.microphoneRequested
        doAssert session.coreOptionValue("melonds_mic_input_active") == "always"
        for frame in 0 ..< 300:
          session.step(if frame in [6, 97]: 256'u16 else: 0'u16)
          let samples = session.takeAudio()
          if frame >= 100: outputs[run].add(samples)
        doAssert toneReads > 0, "The recording ROM must consume microphone PCM"
      finally: session.close()
    finally: host.close()
  doAssert outputs[0].len > 0 and outputs[0].len == outputs[1].len
  doAssert outputs[0] != outputs[1], "Recorded microphone tone must differ from silence"

testAdapter()
testNegotiatedRate()
testInputGain()
testWorker()
doAssert paramCount() in [0, 2], "Optional arguments: melonDS DS core and micrecord.nds"
if paramCount() == 2: testMelonDs(paramStr(1), paramStr(2))
