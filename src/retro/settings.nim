import
  std/[json, os, parseopt, strutils],
  ./input

type
  DeviceKind* = enum
    genericDevice, rgSpDevice, rgDsPlusDevice, rgDsPlusRocknixDevice
  StickBinding* = object
    label*, device*: string
    x*, y*: uint16
  Settings* = object
    title*, framebuffer*, audioDevice*, preview*, command*, saveProfile*: string
    display*, drmDevice*, touchName*, gamepad*, batterySupply*: string
    batteryCurrentSupply*: string
    volumeCard*: string
    volumeInverted*: bool
    outputs*: seq[string]
    volumeControls*: seq[string]
    sticks*: seq[StickBinding]
    inputNames*, inputDevices*: seq[string]
    bindings*: seq[Binding]
    rotation*, touchRotation*, seconds*, toneKey*, audioPrebufferMs*: int

const
  DefaultAudioPrebufferMs = 30
  MaxAudioPrebufferMs = 100
  RgSpProfile = staticRead("../../profiles/rg-sp.json")
  RgDsPlusProfile = staticRead("../../profiles/rg-ds-plus.json")
  RgDsPlusRocknixProfile = staticRead("../../profiles/rg-ds-plus-rocknix.json")

proc identifyDevice*(compatible: string, inputs: seq[string],
    framebufferSize: string, dsiCount: int): DeviceKind =
  ## Identify supported boards from a combination of hardware signatures.
  if "anbernic,rg-ds-plus" in compatible and "retrogame_joypad" in inputs and dsiCount == 2:
    rgDsPlusRocknixDevice
  elif "rockchip,rk3568" in compatible and "ANBERNIC-rk3568-keys" in inputs and dsiCount == 2:
    rgDsPlusDevice
  elif ("sun50iw9" in compatible or "sun50i-h700" in compatible) and
      "ANBERNIC-keys" in inputs and framebufferSize.startsWith("720,"):
    rgSpDevice
  else:
    genericDevice

proc detectDevice*(): DeviceKind =
  ## Read device-tree and sysfs identifiers without changing hardware state.
  var
    compatible = ""
    framebufferSize = ""
    inputs: seq[string]
    dsiCount = 0
  if fileExists("/proc/device-tree/compatible"):
    compatible = readFile("/proc/device-tree/compatible")
  if fileExists("/sys/class/graphics/fb0/virtual_size"):
    framebufferSize = readFile("/sys/class/graphics/fb0/virtual_size").strip()
  for path in walkFiles("/sys/class/input/event*/device/name"):
    inputs.add readFile(path).strip()
  for path in walkFiles("/sys/class/drm/card*-DSI-*/status"):
    if readFile(path).strip() == "connected":
      inc dsiCount
  identifyDevice(compatible, inputs, framebufferSize, dsiCount)

proc defaultSettings*(): Settings =
  ## Return defaults for an unprofiled device.
  Settings(title: "LINUX HANDHELD", framebuffer: "/dev/fb0", audioDevice: "default",
    display: "auto", drmDevice: "/dev/dri/card0", gamepad: "paddy",
    command: "test", seconds: 300, toneKey: 315, audioPrebufferMs: DefaultAudioPrebufferMs)

proc applyProfile*(settings: var Settings, profile: JsonNode) =
  ## Apply explicit JSON settings while retaining unspecified defaults.
  for key, value in profile:
    case key
    of "title": settings.title = value.getStr()
    of "framebuffer": settings.framebuffer = value.getStr()
    of "display": settings.display = value.getStr()
    of "drmDevice": settings.drmDevice = value.getStr()
    of "outputs":
      settings.outputs = @[]
      for output in value: settings.outputs.add output.getStr()
    of "touchName": settings.touchName = value.getStr()
    of "batterySupply": settings.batterySupply = value.getStr()
    of "batteryCurrentSupply": settings.batteryCurrentSupply = value.getStr()
    of "touchRotation": settings.touchRotation = value.getInt()
    of "sticks":
      settings.sticks = @[]
      for stick in value:
        let
          x = stick["x"].getInt()
          y = stick["y"].getInt()
        if x notin 0..63 or y notin 0..63 or x == y:
          raise newException(ValueError, "Invalid joystick axes")
        settings.sticks.add StickBinding(label: stick["label"].getStr(),
          device: stick["device"].getStr(), x: uint16(x), y: uint16(y))
    of "audioDevice": settings.audioDevice = value.getStr()
    of "audioPrebufferMs": settings.audioPrebufferMs = value.getInt()
    of "volumeCard": settings.volumeCard = value.getStr()
    of "volumeControls":
      settings.volumeControls = @[]
      for control in value:
        settings.volumeControls.add control.getStr()
    of "volumeInverted": settings.volumeInverted = value.getBool()
    of "rotation": settings.rotation = value.getInt()
    of "toneKey": settings.toneKey = value.getInt()
    of "bindings":
      settings.bindings = @[]
      for entry in value:
        let
          kind = entry["kind"].getInt()
          code = entry["code"].getInt()
          direction = entry["value"].getInt()
        if kind notin [1, 3] or code notin 0..767 or direction notin [-1, 1]:
          raise newException(ValueError, "Invalid input binding")
        settings.bindings.add Binding(label: entry["label"].getStr(),
          device: entry["device"].getStr(), kind: uint16(kind), code: uint16(code), value: int32(direction))
    of "inputNames":
      settings.inputNames = @[]
      for name in value:
        settings.inputNames.add name.getStr()
    else: raise newException(ValueError, "Unknown profile setting: " & key)

proc validate*(settings: Settings) =
  ## Validate device settings before opening hardware.
  if settings.audioPrebufferMs notin 1..MaxAudioPrebufferMs:
    raise newException(ValueError, "Audio prebuffer must be between 1 and " & $MaxAudioPrebufferMs & " ms")
  if settings.gamepad notin ["paddy", "raw"]:
    raise newException(ValueError, "Gamepad must be paddy or raw")
  if settings.rotation notin [0, 90, 180, 270]:
    raise newException(ValueError, "Rotation must be 0, 90, 180 or 270")
  if settings.touchRotation notin [0, 90, 180, 270]:
    raise newException(ValueError, "Touch rotation must be 0, 90, 180 or 270")
  if settings.display notin ["auto", "x11", "fbdev", "drm"]:
    raise newException(ValueError, "Display must be auto, x11, fbdev or drm")
  for index, output in settings.outputs:
    if output.len == 0 or output in settings.outputs[0 ..< index]:
      raise newException(ValueError, "Display outputs must be unique nonempty names")
  if settings.seconds notin 1..3600:
    raise newException(ValueError, "Duration must be between 1 and 3600 seconds")
  if settings.toneKey notin 0..767:
    raise newException(ValueError, "Tone key must be a Linux key code between 0 and 767")
  if settings.command notin ["test", "info", "input", "audio", "calibrate", "help"]:
    raise newException(ValueError, "Unknown command: " & settings.command)
  if settings.command == "calibrate" and settings.saveProfile.len == 0:
    raise newException(ValueError, "Calibration requires --save-profile:PATH")
  if settings.volumeCard.len == 0 and settings.volumeControls.len > 0:
    raise newException(ValueError, "Volume controls require a volume card")
  for index, control in settings.volumeControls:
    if control.len == 0 or control in settings.volumeControls[0 ..< index]:
      raise newException(ValueError, "Volume controls must be unique nonempty names")

proc parseSettings*(arguments: seq[string], detected = genericDevice): Settings =
  result = defaultSettings()
  var
    device = detected
    outputsOverridden = false
  var parser = initOptParser(arguments)
  for kind, key, value in parser.getopt():
    if kind == cmdLongOption and key == "device":
      case value
      of "auto": device = detected
      of "generic": device = genericDevice
      of "rg-sp": device = rgSpDevice
      of "rg-ds-plus": device = rgDsPlusDevice
      of "rg-ds-plus-rocknix": device = rgDsPlusRocknixDevice
      else: raise newException(ValueError, "Unknown device: " & value)
  case device
  of rgSpDevice: result.applyProfile(parseJson(RgSpProfile))
  of rgDsPlusDevice: result.applyProfile(parseJson(RgDsPlusProfile))
  of rgDsPlusRocknixDevice: result.applyProfile(parseJson(RgDsPlusRocknixProfile))
  of genericDevice: discard
  parser = initOptParser(arguments)
  for kind, key, value in parser.getopt():
    if kind == cmdLongOption and key == "profile":
      result.applyProfile(parseFile(value))
  parser = initOptParser(arguments)
  for kind, key, value in parser.getopt():
    case kind
    of cmdArgument: result.command = key
    of cmdLongOption, cmdShortOption:
      case key
      of "profile", "device": discard
      of "help", "h": result.command = "help"
      of "fb":
        result.framebuffer = value
        result.display = "fbdev"
      of "display": result.display = value
      of "gamepad": result.gamepad = value
      of "drm":
        result.drmDevice = value
        result.display = "drm"
      of "output":
        if not outputsOverridden:
          result.outputs = @[]
          outputsOverridden = true
        result.outputs.add value
      of "touch-rotate": result.touchRotation = parseInt(value)
      of "input": result.inputDevices.add value
      of "pcm": result.audioDevice = value
      of "rotate": result.rotation = parseInt(value)
      of "seconds": result.seconds = parseInt(value)
      of "tone-key": result.toneKey = parseInt(value)
      of "preview": result.preview = value
      of "save-profile": result.saveProfile = value
      else: raise newException(ValueError, "Unknown option: " & key)
    of cmdEnd: discard
  result.validate()
