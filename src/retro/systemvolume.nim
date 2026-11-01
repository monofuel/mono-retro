## Shared hardware volume control for profile-owned ALSA mixers and raw volume keys.

import
  std/[dynlib, json, monotimes, os],
  ./[input, playersave, settings]

type
  SndMixer = object
  SndMixerElem = object
  AlsaApi = object
    library: LibHandle
    mixerOpen: proc(handle: ptr ptr SndMixer, mode: cint): cint {.cdecl, gcsafe.}
    mixerAttach: proc(mixer: ptr SndMixer, name: cstring): cint {.cdecl, gcsafe.}
    mixerRegister: proc(mixer: ptr SndMixer, options, classp: pointer): cint {.cdecl, gcsafe.}
    mixerLoad: proc(mixer: ptr SndMixer): cint {.cdecl, gcsafe.}
    mixerClose: proc(mixer: ptr SndMixer): cint {.cdecl, gcsafe.}
    mixerHandleEvents: proc(mixer: ptr SndMixer): cint {.cdecl, gcsafe.}
    firstElem: proc(mixer: ptr SndMixer): ptr SndMixerElem {.cdecl, gcsafe.}
    elemNext: proc(elem: ptr SndMixerElem): ptr SndMixerElem {.cdecl, gcsafe.}
    elemName: proc(elem: ptr SndMixerElem): cstring {.cdecl, gcsafe.}
    hasPlaybackVolume: proc(elem: ptr SndMixerElem): cint {.cdecl, gcsafe.}
    getRange: proc(elem: ptr SndMixerElem, minimum, maximum: ptr clong): cint {.cdecl, gcsafe.}
    getVolume: proc(elem: ptr SndMixerElem, channel: cint, value: ptr clong): cint {.cdecl, gcsafe.}
    setVolumeAll: proc(elem: ptr SndMixerElem, value: clong): cint {.cdecl, gcsafe.}
    strerror: proc(code: cint): cstring {.cdecl, gcsafe.}
  VolumeMixer* = ref object
    minimum*, maximum*: seq[int64]
    readRaw*: proc(): seq[int64] {.closure.}
    writeRaw*: proc(values: seq[int64]) {.closure.}
    close*: proc() {.closure.}
  RepeatState* = object
    heldSinceNs*, nextRepeatNs*: int64
  SystemVolume* = ref object
    percent*: int
    error*: string
    revision*: uint64
    mixer: VolumeMixer
    inputs: seq[InputDevice]
    decreaseBindings, increaseBindings: seq[Binding]
    decreaseRepeat, increaseRepeat: RepeatState
    statePath: string
    inverted: bool
    toastDeadlineNs, lastMixerPollNs: int64
    mixerPollStarted: bool
    closed: bool

const
  VolumeStepPercent* = 5
  VolumeRepeatDelayNs* = 400_000_000'i64
  VolumeRepeatIntervalNs* = 100_000_000'i64
  MixerPollIntervalNs* = 250_000_000'i64
  VolumeToastDurationNs* = 2_000_000_000'i64
  MixerFrontLeft = 0.cint

proc alsaError(api: AlsaApi, action: string, code: cint): ref IOError =
  ## Convert an ALSA failure code into an actionable Nim exception.
  let detail = if api.strerror == nil: $code else: $api.strerror(code)
  newException(IOError, action & ": " & detail)

proc checkAlsa(api: AlsaApi, action: string, code: cint) =
  ## Raise when a dynamically loaded ALSA operation reports failure.
  if code < 0:
    raise api.alsaError(action, code)

proc loadAlsa(): AlsaApi =
  ## Load only the ALSA mixer ABI needed by the shared volume controller.
  result.library = loadLib("libasound.so.2")
  if result.library == nil:
    raise newException(IOError, "Cannot load libasound.so.2")
  template bindSymbol(field: untyped, name: string) =
    result.field = cast[type(result.field)](symAddr(result.library, name))
    if result.field == nil:
      unloadLib(result.library)
      raise newException(IOError, "Missing ALSA symbol: " & name)
  bindSymbol(mixerOpen, "snd_mixer_open")
  bindSymbol(mixerAttach, "snd_mixer_attach")
  bindSymbol(mixerRegister, "snd_mixer_selem_register")
  bindSymbol(mixerLoad, "snd_mixer_load")
  bindSymbol(mixerClose, "snd_mixer_close")
  bindSymbol(mixerHandleEvents, "snd_mixer_handle_events")
  bindSymbol(firstElem, "snd_mixer_first_elem")
  bindSymbol(elemNext, "snd_mixer_elem_next")
  bindSymbol(elemName, "snd_mixer_selem_get_name")
  bindSymbol(hasPlaybackVolume, "snd_mixer_selem_has_playback_volume")
  bindSymbol(getRange, "snd_mixer_selem_get_playback_volume_range")
  bindSymbol(getVolume, "snd_mixer_selem_get_playback_volume")
  bindSymbol(setVolumeAll, "snd_mixer_selem_set_playback_volume_all")
  bindSymbol(strerror, "snd_strerror")

proc rawToPercent*(raw, minimum, maximum: int64, inverted: bool): int =
  ## Convert a discovered ALSA raw value into the user-facing 0 to 100 scale.
  if maximum <= minimum:
    raise newException(ValueError, "Mixer volume range is invalid")
  let bounded = clamp(raw, minimum, maximum)
  let offset = if inverted: maximum - bounded else: bounded - minimum
  int((offset * 100 + (maximum - minimum) div 2) div (maximum - minimum))

proc percentToRaw*(percent: int, minimum, maximum: int64, inverted: bool): int64 =
  ## Convert the user-facing 0 to 100 scale into a discovered ALSA raw value.
  if maximum <= minimum:
    raise newException(ValueError, "Mixer volume range is invalid")
  let offset = (int64(clamp(percent, 0, 100)) * (maximum - minimum) + 50) div 100
  if inverted: maximum - offset else: minimum + offset

proc repeatDue*(state: var RepeatState, pressed: bool, nowNs: int64): bool =
  ## Return one immediate edge or due hold repeat while preserving its schedule.
  if not pressed:
    state = RepeatState()
    return false
  if state.heldSinceNs == 0:
    state.heldSinceNs = max(1'i64, nowNs)
    state.nextRepeatNs = nowNs + VolumeRepeatDelayNs
    return true
  if nowNs < state.nextRepeatNs:
    return false
  while state.nextRepeatNs <= nowNs:
    state.nextRepeatNs += VolumeRepeatIntervalNs
  true

proc makeAlsaMixer(card: string, controls: seq[string]): VolumeMixer =
  ## Open one profile-owned ALSA card and find each requested simple element.
  var
    api = loadAlsa()
    handle: ptr SndMixer
  try:
    api.checkAlsa("Opening mixer", api.mixerOpen(addr handle, 0))
    api.checkAlsa("Attaching mixer " & card, api.mixerAttach(handle, ("hw:" & card).cstring))
    api.checkAlsa("Registering mixer controls", api.mixerRegister(handle, nil, nil))
    api.checkAlsa("Loading mixer controls", api.mixerLoad(handle))
    var elements: seq[ptr SndMixerElem]
    result = VolumeMixer()
    for control in controls:
      var element = api.firstElem(handle)
      while element != nil and (api.elemName(element) == nil or $api.elemName(element) != control):
        element = api.elemNext(element)
      if element == nil or api.hasPlaybackVolume(element) == 0:
        raise newException(IOError, "Missing playback mixer control: " & control)
      var minimum, maximum: clong
      api.checkAlsa("Reading mixer range " & control, api.getRange(element, addr minimum, addr maximum))
      if maximum <= minimum:
        raise newException(IOError, "Invalid mixer range for " & control)
      elements.add element
      result.minimum.add minimum.int64
      result.maximum.add maximum.int64
    result.readRaw = proc(): seq[int64] =
      api.checkAlsa("Handling mixer events", api.mixerHandleEvents(handle))
      for index, element in elements:
        var value: clong
        api.checkAlsa("Reading mixer volume " & controls[index],
          api.getVolume(element, MixerFrontLeft, addr value))
        result.add value.int64
    result.writeRaw = proc(values: seq[int64]) =
      if values.len != elements.len:
        raise newException(ValueError, "Mixer write has the wrong channel count")
      for index, element in elements:
        api.checkAlsa("Writing mixer volume " & controls[index],
          api.setVolumeAll(element, values[index].clong))
    result.close = proc() =
      if handle != nil:
        discard api.mixerClose(handle)
        handle = nil
      if api.library != nil:
        unloadLib(api.library)
        api.library = nil
  except:
    if handle != nil:
      discard api.mixerClose(handle)
    if api.library != nil:
      unloadLib(api.library)
    raise

proc readPercent(volume: SystemVolume): int =
  ## Read every configured control and reduce their normalized values to one value.
  let values = volume.mixer.readRaw()
  if values.len != volume.mixer.minimum.len or values.len != volume.mixer.maximum.len:
    raise newException(IOError, "Mixer returned an incomplete channel set")
  var total = 0
  for index, value in values:
    total += rawToPercent(value, volume.mixer.minimum[index], volume.mixer.maximum[index], volume.inverted)
  if values.len == 0:
    raise newException(IOError, "Mixer returned no controls")
  total div values.len

proc savePercent(volume: SystemVolume) =
  ## Persist the confirmed mixer value atomically after a successful readback.
  writeSave(volume.statePath, $(%*{"percent": volume.percent}))

proc savedPercent(path: string): int =
  ## Load and validate a previously persisted user-facing volume percentage.
  let document = parseJson(readFile(path))
  if document.kind != JObject or not document.hasKey("percent") or
      document["percent"].kind != JInt or document["percent"].getInt() notin 0..100:
    raise newException(ValueError, "Invalid saved volume")
  document["percent"].getInt()

proc reportError(volume: SystemVolume, message: string) =
  ## Record a boundary failure and emit one diagnostic without reporting success.
  if volume.error == message:
    return
  volume.error = message
  volume.toastDeadlineNs = getMonoTime().ticks + VolumeToastDurationNs
  stderr.writeLine("system volume: " & message)
  inc volume.revision

proc setPercent(volume: SystemVolume, percent: int, nowNs: int64,
    showToast = true): bool =
  ## Write all channels, read them back, and persist only their confirmed value.
  if volume == nil or volume.mixer == nil:
    return false
  try:
    var values: seq[int64]
    for index in 0 ..< volume.mixer.minimum.len:
      values.add percentToRaw(percent, volume.mixer.minimum[index], volume.mixer.maximum[index], volume.inverted)
    volume.mixer.writeRaw(values)
    let confirmed = volume.readPercent()
    let changed = confirmed != volume.percent or volume.error.len > 0
    volume.percent = confirmed
    volume.error = ""
    volume.lastMixerPollNs = nowNs
    volume.mixerPollStarted = true
    if showToast:
      volume.toastDeadlineNs = nowNs + VolumeToastDurationNs
    if changed:
      inc volume.revision
    try:
      volume.savePercent()
    except CatchableError as error:
      volume.reportError("Saving volume: " & error.msg)
    changed
  except CatchableError as error:
    volume.reportError("Writing volume: " & error.msg)
    false

proc matchingBindings(settings: Settings, label: string): seq[Binding] =
  ## Collect only the raw evdev bindings dedicated to one volume direction.
  for binding in settings.bindings:
    if binding.label == label:
      result.add binding

proc bindingActive(bindings: seq[Binding], devices: seq[InputDevice]): bool =
  ## Read held state from input's synchronized control snapshot, not queued edges.
  for binding in bindings:
    if binding.active(devices):
      return true

proc openVolumeInputs(volume: SystemVolume, settings: Settings) =
  ## Open only event devices named by the configured VOL-/VOL+ bindings.
  var names: seq[string]
  for binding in volume.decreaseBindings & volume.increaseBindings:
    if binding.device notin names:
      names.add binding.device
  if names.len == 0:
    raise newException(IOError, "Missing VOL-/VOL+ bindings")
  for path in inputPaths(names):
    let device = openInput(path)
    if device.name in names:
      volume.inputs.add device
  if volume.inputs.len == 0:
    raise newException(IOError, "Missing volume input device")

proc newVolumeFromMixer*(settings: Settings, mixer: VolumeMixer,
    statePath = "/var/lib/mono-retro/volume.json"): SystemVolume =
  ## Build a testable controller around a supplied mixer without opening evdev.
  if mixer == nil:
    raise newException(ValueError, "Volume mixer is required")
  if mixer.minimum.len == 0 or mixer.minimum.len != mixer.maximum.len or
      mixer.readRaw == nil or mixer.writeRaw == nil:
    raise newException(ValueError, "Volume mixer is incomplete")
  result = SystemVolume(mixer: mixer, statePath: statePath, inverted: settings.volumeInverted)
  try:
    result.percent = result.readPercent()
    if fileExists(statePath):
      discard result.setPercent(savedPercent(statePath), 0, false)
  except CatchableError as error:
    result.reportError("Opening mixer: " & error.msg)

proc openSystemVolume*(settings: Settings,
    statePath = "/var/lib/mono-retro/volume.json"): SystemVolume =
  ## Open profile-owned mixer and volume-key inputs, or nil when unconfigured.
  if settings.volumeCard.len == 0 or settings.volumeControls.len == 0:
    return nil
  try:
    result = newVolumeFromMixer(settings, makeAlsaMixer(settings.volumeCard, settings.volumeControls), statePath)
  except CatchableError as error:
    result = SystemVolume(statePath: statePath, inverted: settings.volumeInverted)
    result.reportError("Opening mixer: " & error.msg)
  result.decreaseBindings = matchingBindings(settings, "VOL-")
  result.increaseBindings = matchingBindings(settings, "VOL+")
  try:
    result.openVolumeInputs(settings)
  except CatchableError as error:
    result.reportError("Opening volume input: " & error.msg)

proc adjust*(volume: SystemVolume, deltaPercent: int, nowNs: int64): bool =
  ## Change the confirmed value by a signed user-facing percentage increment.
  if volume == nil or deltaPercent == 0:
    return false
  volume.setPercent(clamp(volume.percent + deltaPercent, 0, 100), nowNs)

proc updateButtons*(volume: SystemVolume, decrease, increase: bool, nowNs: int64) =
  ## Apply synchronized key states while cancelling opposed buttons and stale repeats.
  if volume.mixer == nil:
    if decrease or increase: volume.toastDeadlineNs = nowNs + VolumeToastDurationNs
    return
  if decrease and increase:
    discard volume.decreaseRepeat.repeatDue(false, nowNs)
    discard volume.increaseRepeat.repeatDue(false, nowNs)
  else:
    let
      downDue = volume.decreaseRepeat.repeatDue(decrease, nowNs)
      upDue = volume.increaseRepeat.repeatDue(increase, nowNs)
    if downDue: discard volume.adjust(-VolumeStepPercent, nowNs)
    elif upDue: discard volume.adjust(VolumeStepPercent, nowNs)

proc poll*(volume: SystemVolume, nowNs: int64): bool =
  ## Drain only volume devices, process hold repeats, and report visible changes.
  if volume == nil or volume.closed:
    return false
  let before = volume.revision
  try:
    for device in volume.inputs:
      discard device.readEvents()
    let decrease = volume.decreaseBindings.bindingActive(volume.inputs)
    let increase = volume.increaseBindings.bindingActive(volume.inputs)
    volume.updateButtons(decrease, increase, nowNs)
  except CatchableError as error:
    volume.reportError("Reading volume input: " & error.msg)
  if volume.mixer != nil and (not volume.mixerPollStarted or
      nowNs - volume.lastMixerPollNs >= MixerPollIntervalNs):
    volume.lastMixerPollNs = nowNs
    volume.mixerPollStarted = true
    try:
      let updated = volume.readPercent()
      if updated != volume.percent:
        volume.percent = updated
        volume.error = ""
        volume.toastDeadlineNs = nowNs + VolumeToastDurationNs
        inc volume.revision
    except CatchableError as error:
      volume.reportError("Reading mixer: " & error.msg)
  volume.revision != before

proc visible*(volume: SystemVolume, nowNs: int64): bool =
  ## Report whether a successful adjustment or external mixer change has a toast.
  volume != nil and nowNs < volume.toastDeadlineNs

proc close*(volume: SystemVolume) =
  ## Release app-owned input descriptors and the dynamically loaded mixer library.
  if volume == nil or volume.closed:
    return
  volume.closed = true
  for device in volume.inputs:
    try:
      device.close()
    except CatchableError as error:
      volume.reportError("Closing volume input: " & error.msg)
  volume.inputs.setLen(0)
  if volume.mixer != nil and volume.mixer.close != nil:
    try:
      volume.mixer.close()
    except CatchableError as error:
      volume.reportError("Closing mixer: " & error.msg)
