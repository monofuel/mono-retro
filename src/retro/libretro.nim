import
  std/[dynlib, math, os, strutils, tables],
  pixie,
  ./[playervideo, playersave]

const
  HeaderDirectory = currentSourcePath.parentDir / "../../third_party"
  CoreApiVersion = 1'u32
  JoypadDevice = 1'u32
  JoypadMask = 256'u32
  SaveRam = 0'u32
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
  GetAudioVideoEnable = 47'u32 or Experimental
  GetInputBitmasks = 51'u32 or Experimental
  GetCoreOptionsVersion = 52'u32

{.passC: "-I" & HeaderDirectory.}
{.compile: "libretrolog.c".}
{.emit: "void mono_retro_log(enum retro_log_level, const char *, ...);".}

type
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
  CoreSession* = ref object
    library: LibHandle
    initialized, loaded, ready: bool
    romPath, romData, systemDirectory, saveDirectory: string
    saved: string
    variables: Table[string, string]
    failure*: string
    shutdown*: bool
    pixelFormat*: int
    image*: Image
    info*: SystemInfo
    av*: AvInfo
    buttons*: uint16
    frames*, videoFrames*, audioFrames*: uint64
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

var active: CoreSession

proc coreLog(level: cint, format: cstring) {.cdecl, varargs, importc: "mono_retro_log", nodecl.}

proc check*(session: CoreSession) =
  ## Surface callback errors only after control has returned across the C ABI.
  if session.failure.len > 0: raise newException(IOError, session.failure)

proc validate*(av: AvInfo) =
  ## Reject dimensions and rates that cannot describe a software game frame.
  if av.geometry.baseWidth == 0 or av.geometry.baseHeight == 0 or
      av.geometry.maxWidth < av.geometry.baseWidth or av.geometry.maxHeight < av.geometry.baseHeight or
      av.geometry.maxWidth > 8192 or av.geometry.maxHeight > 8192 or
      av.geometry.aspectRatio.classify in {fcNan, fcInf, fcNegInf} or
      av.geometry.aspectRatio < 0 or av.timing.fps.classify in {fcNan, fcInf, fcNegInf} or
      av.timing.fps <= 0 or av.timing.fps > 1000:
    raise newException(ValueError, "Invalid core video geometry or timing")

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
        active.failure = "Unsupported core pixel format: " & $format
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
          let value = description[separator + 1 .. ^1].strip().split('|')[0]
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
    active.image = copyFrame(active.image, data, int(width), int(height), int(pitch), active.pixelFormat)
    if data != nil: inc active.videoFrames
  except CatchableError as error:
    active.failure = error.msg

proc audio(left, right: int16) {.cdecl.} =
  ## Consume audio without opening a device or changing the core's timing.
  inc active.audioFrames

proc audioBatch(data: ptr int16, frames: csize_t): csize_t {.cdecl.} =
  ## Acknowledge every stereo frame without playing or retaining it.
  active.audioFrames += uint64(frames)
  frames

proc poll() {.cdecl.} =
  ## Input is a stable snapshot for the duration of one emulated frame.
  discard

proc input(port, device, index, id: cuint): int16 {.cdecl.} =
  ## Expose one digital RetroPad, including the optional bitmask query.
  if port != 0 or device != JoypadDevice or index != 0: return 0
  if id == JoypadMask: return cast[int16](active.buttons)
  if id < 16: return int16((active.buttons shr id) and 1)

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

proc openCore*(corePath, romPath, saveDirectory: string): CoreSession =
  ## Load one explicitly selected software core and an independent save history.
  if active != nil: raise newException(ValueError, "Only one libretro core can be active")
  if not fileExists(corePath): raise newException(IOError, "Missing core: " & corePath)
  if not fileExists(romPath): raise newException(IOError, "Missing ROM: " & romPath)
  result = CoreSession(romPath: absolutePath(romPath), saveDirectory: absolutePath(saveDirectory))
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
    var game = GameInfo(path: session.romPath.cstring)
    if not session.info.needFullpath:
      game.size = csize_t(session.romData.len)
      if session.romData.len > 0: game.data = addr session.romData[0]
    if not session.loadGame(addr game): raise newException(IOError, "Core rejected the ROM")
    session.loaded = true
    session.check()
    session.setController(0, JoypadDevice)
    session.getAv(addr session.av)
    session.av.validate()
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
    session.ready = true
  except:
    session.close()
    raise

proc step*(session: CoreSession, buttons: uint16) =
  ## Advance exactly one frame with the frontend's current input snapshot.
  session.buttons = buttons
  session.run()
  inc session.frames
  session.check()
