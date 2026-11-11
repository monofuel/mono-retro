import
  std/[dynlib, math, os, strutils, tables],
  pixie,
  ./[playerformats, playerprofile, playervideo, playersave, ra_types]

const
  HeaderDirectory = currentSourcePath.parentDir / "../../third_party"
  CoreApiVersion = 1'u32
  JoypadDevice = 1'u32
  JoypadMask = 256'u32
  PointerDevice = 6'u32
  SaveRam = 0'u32
  SystemRam = 2'u32
  MaxSaveBytes = 64 * 1024 * 1024
  Experimental = 0x10000'u32
  GetCanDupe = 3'u32
  Shutdown = 7'u32
  SetPerformanceLevel = 8'u32
  GetSystemDirectory = 9'u32
  SetPixelFormat = 10'u32
  SetInputDescriptors = 11'u32
  GetVariable = 15'u32
  SetVariables = 16'u32
  GetVariableUpdate = 17'u32
  SetSupportNoGame = 18'u32
  GetLogInterface = 27'u32
  GetSaveDirectory = 31'u32
  SetSystemAvInfo = 32'u32
  SetControllerInfo = 35'u32
  SetGeometry = 37'u32
  SetSupportAchievements = 42'u32 or Experimental
  GetAudioVideoEnable = 47'u32 or Experimental
  GetInputBitmasks = 51'u32 or Experimental
  GetCoreOptionsVersion = 52'u32

{.passC: "-I" & HeaderDirectory.}
{.compile: "libretrolog.c".}
{.emit: "void mono_retro_log(enum retro_log_level, const char *, ...);".}

type
  CoreOption* = tuple[key, value: string]
  PointerInput* = object
    x*, y*: int16
    pressed*: bool
  SystemInfo* {.bycopy, importc: "struct retro_system_info", header: "libretro.h".} = object
    libraryName* {.importc: "library_name".}: cstring
    libraryVersion* {.importc: "library_version".}: cstring
    validExtensions* {.importc: "valid_extensions".}: cstring
    needFullpath* {.importc: "need_fullpath".}: bool
    blockExtract* {.importc: "block_extract".}: bool
  GameInfo {.bycopy, importc: "struct retro_game_info", header: "libretro.h".} = object
    path: cstring
    data: pointer
    size: csize_t
    meta: cstring
  Geometry* {.bycopy, importc: "struct retro_game_geometry", header: "libretro.h".} = object
    baseWidth* {.importc: "base_width".}: cuint
    baseHeight* {.importc: "base_height".}: cuint
    maxWidth* {.importc: "max_width".}: cuint
    maxHeight* {.importc: "max_height".}: cuint
    aspectRatio* {.importc: "aspect_ratio".}: cfloat
  Timing* {.bycopy, importc: "struct retro_system_timing", header: "libretro.h".} = object
    fps*: cdouble
    sampleRate* {.importc: "sample_rate".}: cdouble
  AvInfo* {.bycopy, importc: "struct retro_system_av_info", header: "libretro.h".} = object
    geometry*: Geometry
    timing*: Timing
  Variable {.bycopy, importc: "struct retro_variable", header: "libretro.h".} = object
    key, value: cstring
  LogInterface {.bycopy, importc: "struct retro_log_callback", header: "libretro.h".} = object
    log: pointer
  EnvironmentCallback = proc(command: cuint, data: pointer): bool {.cdecl.}
  VideoCallback = proc(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.}
  AudioCallback = proc(left, right: int16) {.cdecl.}
  AudioBatchCallback = proc(data: ptr int16, frames: csize_t): csize_t {.cdecl.}
  PollCallback = proc() {.cdecl.}
  InputCallback = proc(port, device, index, id: cuint): int16 {.cdecl.}
  UnserializeCallback = proc(data: pointer, size: csize_t): bool {.cdecl.}
  SerializeSizeCallback = proc(): csize_t {.cdecl.}
  SerializeCallback = proc(data: pointer, size: csize_t): bool {.cdecl.}
  CoreSession* = ref object
    library: LibHandle
    initialized, loaded, ready: bool
    romPath, romData, achievementRomData, systemDirectory, saveDirectory: string
    achievementSupport: bool
    saved: string
    variables: Table[string, string]
    options: seq[CoreOption]
    failure*: string
    shutdown*: bool
    pixelFormat*: int
    image*: Image
    info*: SystemInfo
    av*: AvInfo
    buttons*: uint16
    pointerInput*: PointerInput
    frames*, videoFrames*, audioFrames*: uint64
    captureAudio, captureVideo: bool
    audioSamples: seq[int16]
    savePath*: string
    apiVersion: proc(): cuint {.cdecl.}
    setEnvironment: proc(callback: EnvironmentCallback) {.cdecl.}
    setVideo: proc(callback: VideoCallback) {.cdecl.}
    setAudio: proc(callback: AudioCallback) {.cdecl.}
    setAudioBatch: proc(callback: AudioBatchCallback) {.cdecl.}
    setPoll: proc(callback: PollCallback) {.cdecl.}
    setInput: proc(callback: InputCallback) {.cdecl.}
    initialize, deinitialize, unloadGame, run: proc() {.cdecl.}
    getInfo: proc(info: ptr SystemInfo) {.cdecl.}
    getAv: proc(info: ptr AvInfo) {.cdecl.}
    loadGame: proc(info: ptr GameInfo): bool {.cdecl.}
    setController: proc(port, device: cuint) {.cdecl.}
    memoryData: proc(id: cuint): pointer {.cdecl.}
    memorySize: proc(id: cuint): csize_t {.cdecl.}
    serializeSize: SerializeSizeCallback
    serialize: SerializeCallback

var active: CoreSession

proc coreLog(level: cint, format: cstring) {.cdecl, varargs, importc: "mono_retro_log", nodecl.}

proc check*(session: CoreSession) =
  ## Surface callback errors only after control has returned across the C ABI.
  if session.failure.len > 0: raise newException(IOError, session.failure)

proc ownedString(value: string): string =
  ## Copy bytes without sharing the buffer supplied to a core or another thread.
  result = newString(value.len)
  if value.len > 0: copyMem(addr result[0], unsafeAddr value[0], value.len)

proc supportsAchievements*(session: CoreSession): bool =
  ## Limit achievement memory access to an explicitly capable Decompbound core.
  session != nil and session.loaded and session.achievementSupport and
    session.info.libraryName != nil and $session.info.libraryName == "Decompbound"

proc originalRomPath*(session: CoreSession): string =
  ## Return an owned copy of the original content path for worker-local hashing.
  ownedString(session.romPath)

proc originalRomData*(session: CoreSession): string =
  ## Return immutable source bytes independently of the buffer passed to the core.
  ownedString(session.achievementRomData)

proc achievementMemoryProvider*(session: CoreSession): RaMemoryProvider =
  ## Borrow RAM only on the core owner thread while the loaded session is alive.
  result = proc(id: uint32): RaMemoryInfo =
    ## Resolve current system or save RAM after imports may replace their storage.
    if not session.supportsAchievements() or id notin [SaveRam, SystemRam]: return
    let size = session.memorySize(id.cuint)
    if size == 0: return
    if size > MaxSaveBytes.csize_t:
      raise newException(IOError, "Core achievement memory exceeds supported size")
    let data = session.memoryData(id.cuint)
    if data == nil: raise newException(IOError, "Core returned missing achievement memory")
    result = RaMemoryInfo(data: data, size: size.int)

proc validate*(av: AvInfo) =
  ## Reject dimensions and rates that cannot describe a software game frame.
  if av.geometry.baseWidth == 0 or av.geometry.baseHeight == 0 or
      av.geometry.maxWidth < av.geometry.baseWidth or av.geometry.maxHeight < av.geometry.baseHeight or
      av.geometry.maxWidth > 8192 or av.geometry.maxHeight > 8192 or
      av.geometry.aspectRatio.classify in {fcNan, fcInf, fcNegInf} or
      av.geometry.aspectRatio < 0 or av.timing.fps.classify in {fcNan, fcInf, fcNegInf} or
      av.timing.fps <= 0 or av.timing.fps > 1000:
    raise newException(ValueError, "Invalid core video geometry or timing")

proc audioFrequency*(rate: float): int =
  ## Convert a positive core sample rate to an OpenAL-compatible frequency.
  if rate.classify in {fcNan, fcInf, fcNegInf} or rate < 1 or rate > high(cint).float:
    raise newException(ValueError, "Invalid core audio sample rate")
  int(round(rate))

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Implement the small software-core feature set advertised by this host.
  try:
    case command
    of Shutdown:
      active.shutdown = true
      return true
    of GetCanDupe:
      if data != nil: cast[ptr bool](data)[] = true; return true
    of SetPerformanceLevel, SetInputDescriptors, SetSupportNoGame, SetControllerInfo:
      return true
    of SetSupportAchievements:
      if data != nil:
        active.achievementSupport = cast[ptr bool](data)[]
        return true
    of GetSystemDirectory, GetSaveDirectory:
      if data != nil:
        cast[ptr cstring](data)[] = if command == GetSystemDirectory: active.systemDirectory.cstring
          else: active.saveDirectory.cstring
        return true
    of SetPixelFormat:
      if data != nil:
        let format = cast[ptr cint](data)[]
        if format in [PixelRgb1555, PixelXrgb8888, PixelRgb565]:
          active.pixelFormat = format
          return true
    of MonoRetroSetPixelFormat:
      when cpuEndian == littleEndian:
        if data != nil and cast[ptr uint32](data)[] == MonoRetroXbgr8888:
          active.pixelFormat = PixelXbgr8888
          return true
    of GetVariable:
      if data != nil:
        let variable = cast[ptr Variable](data)
        if variable.key != nil and active.variables.hasKey($variable.key):
          variable.value = active.variables[$variable.key].cstring
          return true
        variable.value = nil
    of SetVariables:
      if data != nil:
        let variables = cast[ptr UncheckedArray[Variable]](data)
        var index = 0
        while variables[index].key != nil:
          let
            key = $variables[index].key
            description = $variables[index].value
            separator = description.find(';')
          if separator < 0: raise newException(ValueError, "Malformed core option: " & key)
          let values = description[separator + 1 .. ^1].strip().split('|')
          var value = values[0]
          for option in active.options:
            if option.key == key:
              if option.value notin values:
                raise newException(ValueError, "Invalid core option: " & key & "=" & option.value)
              value = option.value
          active.variables[key] = value
          inc index
        return true
    of GetVariableUpdate:
      if data != nil: cast[ptr bool](data)[] = false; return true
    of GetLogInterface:
      if data != nil: cast[ptr LogInterface](data).log = cast[pointer](coreLog); return true
    of SetSystemAvInfo:
      if data != nil:
        let av = cast[ptr AvInfo](data)[]
        av.validate()
        if active.captureAudio:
          discard audioFrequency(av.timing.sampleRate)
          if av.timing.sampleRate != active.av.timing.sampleRate:
            active.audioSamples.setLen(0)
        active.av = av
        return true
    of SetGeometry:
      if data != nil:
        var av = active.av
        av.geometry = cast[ptr Geometry](data)[]
        if av.timing.fps == 0: av.timing.fps = 60
        av.validate()
        active.av.geometry = av.geometry
        return true
    of GetAudioVideoEnable:
      if data != nil: cast[ptr cint](data)[] = 3; return true
    of GetInputBitmasks:
      return true
    of GetCoreOptionsVersion:
      if data != nil: cast[ptr cuint](data)[] = 0; return true
    else:
      return false
  except CatchableError as error:
    if active.failure.len == 0: active.failure = error.msg

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Retain video pixels independently of the core's next emulation step.
  if active.failure.len > 0: return
  try:
    if active.captureVideo:
      measured(VideoCopy):
        active.image = copyFrame(active.image, data, int(width), int(height), int(pitch), active.pixelFormat)
    if data != nil: inc active.videoFrames
  except CatchableError as error:
    active.failure = error.msg

proc audio(left, right: int16) {.cdecl.} =
  ## Copy one stereo frame before returning to the core.
  inc active.audioFrames
  if not active.captureAudio or active.failure.len > 0: return
  try:
    measured(AudioCapture):
      active.audioSamples.add(left)
      active.audioSamples.add(right)
  except CatchableError as error:
    active.failure = error.msg

proc audioBatch(data: ptr int16, frames: csize_t): csize_t {.cdecl.} =
  ## Copy borrowed stereo samples and acknowledge the complete batch.
  active.audioFrames += uint64(frames)
  result = frames
  if not active.captureAudio or active.failure.len > 0 or frames == 0: return
  try:
    if data == nil or frames > csize_t(high(int) div (2 * sizeof(int16))):
      raise newException(ValueError, "Invalid core audio batch")
    let
      offset = active.audioSamples.len
      count = int(frames) * 2
    if count > high(int) - offset: raise newException(ValueError, "Core audio batch is too large")
    measured(AudioCapture):
      active.audioSamples.setLen(offset + count)
      copyMem(addr active.audioSamples[offset], data, count * sizeof(int16))
  except CatchableError as error:
    active.failure = error.msg

proc takeAudio*(session: CoreSession): seq[int16] =
  ## Transfer captured stereo samples to the frontend without retaining a copy.
  result = move(session.audioSamples)

proc poll() {.cdecl.} =
  ## Input is a stable snapshot for the duration of one emulated frame.
  discard

proc input(port, device, index, id: cuint): int16 {.cdecl.} =
  ## Expose a digital RetroPad and one normalized pointer snapshot.
  if port != 0 or index != 0: return 0
  case device
  of JoypadDevice:
    if id == JoypadMask: return cast[int16](active.buttons)
    if id < 16: return int16((active.buttons shr id) and 1)
  of PointerDevice:
    case id
    of 0: return active.pointerInput.x
    of 1: return active.pointerInput.y
    of 2, 3: return int16(active.pointerInput.pressed)
    else: discard
  else: discard

proc save*(session: CoreSession) =
  ## Persist the current core-reported save RAM only when its bytes change.
  if not session.ready: return
  let size = session.memorySize(SaveRam)
  if size == 0: return
  if size > MaxSaveBytes.csize_t: raise newException(IOError, "Core save RAM exceeds supported size")
  let data = session.memoryData(SaveRam)
  if data == nil: raise newException(IOError, "Core returned missing save RAM")
  var contents = newString(int(size))
  copyMem(addr contents[0], data, contents.len)
  if contents != session.saved:
    writeSave(session.savePath, contents)
    session.saved = contents

proc canImportState*(session: CoreSession): bool =
  ## Report whether the loaded core exposes the optional restoration callback.
  session != nil and session.loaded and symAddr(session.library, "retro_unserialize") != nil

proc importStateData*(session: CoreSession, contents: string, source: string) =
  ## Pass opaque core-defined save-state bytes through optional retro_unserialize.
  if session == nil or not session.loaded:
    raise newException(IOError, "State import requires a loaded session")
  if contents.len == 0:
    raise newException(IOError, "State file is empty: " & source)
  if contents.len > MaxSaveBytes:
    raise newException(IOError, "State file exceeds supported size")
  # Resolve the callback only for an explicit import so cores without it still open.
  let address = symAddr(session.library, "retro_unserialize")
  if address == nil:
    raise newException(IOError, "Core does not support save state import")
  let
    unserialize = cast[UnserializeCallback](address)
    accepted = unserialize(unsafeAddr contents[0], csize_t(contents.len))
  session.check()
  if not accepted:
    raise newException(IOError, "Core rejected the save state")
  session.audioSamples.setLen(0)
  session.buttons = 0
  session.pointerInput = PointerInput()

proc stateSize*(session: CoreSession): int =
  ## Query optional state export without requiring unsupported cores to implement it.
  if session == nil or not session.loaded or session.serializeSize == nil or
      session.serialize == nil: return 0
  let size = session.serializeSize()
  session.check()
  if size > MaxSaveBytes.csize_t:
    raise newException(IOError, "Core state exceeds supported size")
  size.int

proc exportState*(session: CoreSession): string =
  ## Copy the current machine state on the thread that owns the libretro session.
  let size = session.stateSize()
  if size == 0: raise newException(IOError, "Core does not support state export")
  result = newString(size)
  let accepted = session.serialize(addr result[0], size.csize_t)
  session.check()
  if not accepted: raise newException(IOError, "Core rejected state export")

proc importState*(session: CoreSession, path: string) =
  ## Read opaque save-state bytes from a file and import them.
  if path.len == 0: return
  if not fileExists(path):
    raise newException(IOError, "Missing state: " & path)
  let size = getFileSize(path)
  if size <= 0:
    raise newException(IOError, "State file is empty: " & path)
  if size > MaxSaveBytes:
    raise newException(IOError, "State file exceeds supported size")
  importStateData(session, readFile(path), path)

proc close*(session: CoreSession) =
  ## Release a partially initialized session even when saving fails.
  if session == nil or session.library == nil: return
  try:
    session.save()
  finally:
    if session.loaded:
      session.unloadGame()
      session.loaded = false
    if session.initialized:
      session.deinitialize()
      session.initialized = false
    unloadLib(session.library)
    session.library = nil
    active = nil

proc coreOptionValue*(session: CoreSession, key: string): string =
  ## Read the effective option, or an empty string when the core did not register it.
  session.variables.getOrDefault(key)

proc openCore*(corePath, romPath, saveDirectory: string, captureAudio = false,
    options: seq[CoreOption] = @[], statePath = "", captureVideo = true,
    stateData = ""): CoreSession =
  ## Load one explicitly selected software core and an independent save history.
  ## Disabling captureVideo discards pixels without requesting skipped core rendering.
  if active != nil: raise newException(ValueError, "Only one libretro core can be active")
  if not fileExists(corePath): raise newException(IOError, "Missing core: " & corePath)
  if not fileExists(romPath): raise newException(IOError, "Missing ROM: " & romPath)
  result = CoreSession(romPath: absolutePath(romPath), saveDirectory: absolutePath(saveDirectory),
    captureAudio: captureAudio, captureVideo: captureVideo, options: options)
  let session = result
  session.systemDirectory = session.saveDirectory / "system"
  session.savePath = session.saveDirectory / romPath.splitFile.name & ".srm"
  session.library = loadLib(absolutePath(corePath))
  if session.library == nil: raise newException(IOError, "Cannot load core: " & corePath)
  active = session
  try:
    template bindSymbol(field, symbol: untyped) =
      let address = symAddr(session.library, symbol)
      if address == nil: raise newException(IOError, "Missing core export: " & symbol)
      session.field = cast[typeof(session.field)](address)
    bindSymbol(apiVersion, "retro_api_version")
    bindSymbol(setEnvironment, "retro_set_environment")
    bindSymbol(setVideo, "retro_set_video_refresh")
    bindSymbol(setAudio, "retro_set_audio_sample")
    bindSymbol(setAudioBatch, "retro_set_audio_sample_batch")
    bindSymbol(setPoll, "retro_set_input_poll")
    bindSymbol(setInput, "retro_set_input_state")
    bindSymbol(initialize, "retro_init")
    bindSymbol(deinitialize, "retro_deinit")
    bindSymbol(getInfo, "retro_get_system_info")
    bindSymbol(getAv, "retro_get_system_av_info")
    bindSymbol(loadGame, "retro_load_game")
    bindSymbol(unloadGame, "retro_unload_game")
    bindSymbol(run, "retro_run")
    bindSymbol(setController, "retro_set_controller_port_device")
    bindSymbol(memoryData, "retro_get_memory_data")
    bindSymbol(memorySize, "retro_get_memory_size")
    session.serializeSize = cast[SerializeSizeCallback](symAddr(session.library, "retro_serialize_size"))
    session.serialize = cast[SerializeCallback](symAddr(session.library, "retro_serialize"))
    if session.apiVersion() != CoreApiVersion:
      raise newException(IOError, "Unsupported libretro API version")
    createDir(session.systemDirectory)
    session.setEnvironment(environment)
    session.setVideo(video)
    session.setAudio(audio)
    session.setAudioBatch(audioBatch)
    session.setPoll(poll)
    session.setInput(input)
    session.check()
    session.initialize()
    session.initialized = true
    session.check()
    session.getInfo(addr session.info)
    if not session.info.needFullpath: session.romData = readFile(session.romPath)
    if session.info.libraryName != nil and $session.info.libraryName == "Decompbound":
      session.achievementRomData = if session.info.needFullpath: readFile(session.romPath)
        else: ownedString(session.romData)
    var game = GameInfo(path: session.romPath.cstring)
    if not session.info.needFullpath:
      game.size = csize_t(session.romData.len)
      if session.romData.len > 0: game.data = addr session.romData[0]
    session.loaded = session.loadGame(addr game)
    session.check()
    if not session.loaded: raise newException(IOError, "Core rejected the ROM")
    for option in session.options:
      if not session.variables.hasKey(option.key):
        raise newException(ValueError, "Core did not register option: " & option.key)
    session.setController(0, JoypadDevice)
    session.getAv(addr session.av)
    session.av.validate()
    if session.captureAudio: discard audioFrequency(session.av.timing.sampleRate)
    if fileExists(session.savePath):
      let
        contents = readFile(session.savePath)
        capacity = session.memorySize(SaveRam)
        target = session.memoryData(SaveRam)
      if contents.len.csize_t > capacity or capacity > MaxSaveBytes.csize_t or
          (contents.len > 0 and target == nil):
        raise newException(IOError, "Existing save does not fit the core's save RAM; refusing to overwrite it")
      if contents.len > 0: copyMem(target, unsafeAddr contents[0], contents.len)
      session.saved = contents
    # Import before ready so a failed load cannot persist SRAM on cleanup.
    if stateData.len > 0: session.importStateData(stateData, statePath)
    else: importState(session, statePath)
    session.ready = true
  except:
    session.close()
    raise

proc step*(session: CoreSession, buttons: uint16, pointerInput = PointerInput()) =
  ## Advance exactly one frame with the frontend's current input snapshot.
  session.buttons = buttons
  session.pointerInput = pointerInput
  session.audioSamples.setLen(0)
  session.run()
  inc session.frames
  session.check()
