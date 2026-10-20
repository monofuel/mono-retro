import
  std/[json, parseopt, strutils],
  ./input

type
  Settings* = object
    title*, framebuffer*, audioDevice*, preview*, command*, saveProfile*: string
    inputNames*, inputDevices*: seq[string]
    bindings*: seq[Binding]
    rotation*, seconds*, toneKey*: int

proc defaultSettings*(): Settings =
  Settings(title: "LINUX HANDHELD", framebuffer: "/dev/fb0", audioDevice: "default",
    command: "test", seconds: 300, toneKey: 315)

proc applyProfile*(settings: var Settings, profile: JsonNode) =
  for key, value in profile:
    case key
    of "title": settings.title = value.getStr()
    of "framebuffer": settings.framebuffer = value.getStr()
    of "audioDevice": settings.audioDevice = value.getStr()
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
  if settings.rotation notin [0, 90, 180, 270]:
    raise newException(ValueError, "Rotation must be 0, 90, 180 or 270")
  if settings.seconds notin 1..3600:
    raise newException(ValueError, "Duration must be between 1 and 3600 seconds")
  if settings.toneKey notin 0..767:
    raise newException(ValueError, "Tone key must be a Linux key code between 0 and 767")
  if settings.command notin ["test", "info", "input", "audio", "calibrate", "help"]:
    raise newException(ValueError, "Unknown command: " & settings.command)
  if settings.command == "calibrate" and settings.saveProfile.len == 0:
    raise newException(ValueError, "Calibration requires --save-profile:PATH")

proc parseSettings*(arguments: seq[string]): Settings =
  result = defaultSettings()
  var parser = initOptParser(arguments)
  for kind, key, value in parser.getopt():
    if kind == cmdLongOption and key == "profile":
      result.applyProfile(parseFile(value))
  parser = initOptParser(arguments)
  for kind, key, value in parser.getopt():
    case kind
    of cmdArgument: result.command = key
    of cmdLongOption, cmdShortOption:
      case key
      of "profile": discard
      of "help", "h": result.command = "help"
      of "fb": result.framebuffer = value
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
