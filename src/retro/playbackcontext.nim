import
  openal

type
  PlaybackContextApi* = object
    openDevice*: proc(name: cstring): ALCdevice {.closure.}
    createContext*: proc(device: ALCdevice): ALCcontext {.closure.}
    makeCurrent*: proc(context: ALCcontext): bool {.closure.}
    destroyContext*: proc(context: ALCcontext) {.closure.}
    closeDevice*: proc(device: ALCdevice): bool {.closure.}
  PlaybackContext* = ref object
    api: PlaybackContextApi
    device: ALCdevice
    context: ALCcontext

proc defaultApi(): PlaybackContextApi =
  ## Bind the narrow context lifecycle without enumerating alternative devices.
  PlaybackContextApi(
    openDevice: proc(name: cstring): ALCdevice = alcOpenDevice(name),
    createContext: proc(device: ALCdevice): ALCcontext = alcCreateContext(device, nil),
    makeCurrent: proc(context: ALCcontext): bool = alcMakeContextCurrent(context),
    destroyContext: proc(context: ALCcontext) = alcDestroyContext(context),
    closeDevice: proc(device: ALCdevice): bool = alcCloseDevice(device))

proc close*(playback: PlaybackContext) =
  ## Release partial initialization as well as a complete app-owned context.
  if playback == nil: return
  try:
    if playback.context != nil:
      let context = playback.context
      playback.context = nil
      try:
        if not playback.api.makeCurrent(nil):
          raise newException(IOError, "Failed to detach the OpenAL context")
      finally:
        playback.api.destroyContext(context)
  finally:
    if playback.device != nil:
      let device = playback.device
      playback.device = nil
      if not playback.api.closeDevice(device):
        raise newException(IOError, "Failed to close the OpenAL playback device")

proc openPlaybackContext*(api: PlaybackContextApi): PlaybackContext =
  ## Open only the configured default; failure never tries another audio device.
  result = PlaybackContext(api: api)
  result.device = api.openDevice(nil)
  if result.device == nil:
    raise newException(IOError, "Failed to open the selected audio output")
  try:
    result.context = api.createContext(result.device)
    if result.context == nil:
      raise newException(IOError, "Failed to create the OpenAL playback context")
    if not api.makeCurrent(result.context):
      raise newException(IOError, "Failed to activate the OpenAL playback context")
  except:
    result.close()
    raise

proc openPlaybackContext*(): PlaybackContext =
  ## Use the configured ALSA PCM exactly once, without Slappy's device retries.
  openPlaybackContext(defaultApi())
