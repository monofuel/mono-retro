import
  std/[json, os, strutils, tempfiles],
  ./[playersave, settings]

type
  AudioOutputSelection* = object
    address*, name*: string
  AudioRoute* = ref object
    settings*: Settings
    headphones*: bool
    previousConfig, temporaryConfig: string
    hadConfig, closed: bool

const
  BoardOpenAlConfig = "/etc/mono-retro/alsoft.conf"
  BlueAlsaMixerPrefix* = "bluealsa:DEV="
  BlueAlsaMixerSuffix* = ",EXT=no,BTT=no,DYN=no"

proc bluetoothAddress*(address: string): string =
  ## Validate an exact device address, excluding BlueALSA's wildcard addresses.
  if address.len != 17:
    raise newException(ValueError, "Invalid Bluetooth audio address")
  for index, character in address:
    if index mod 3 == 2:
      if character != ':':
        raise newException(ValueError, "Invalid Bluetooth audio address")
    elif character notin HexDigits:
      raise newException(ValueError, "Invalid Bluetooth audio address")
  result = address.toUpperAscii()
  if result in ["00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"]:
    raise newException(ValueError, "Bluetooth audio requires a specific device")

proc audioOutputPath*(): string =
  ## Return the user-owned output preference shared by launcher and applications.
  getConfigDir() / "mono-retro" / "audio-output.json"

proc loadAudioOutput*(): AudioOutputSelection =
  ## Load the selected output without silently replacing an invalid preference.
  let path = audioOutputPath()
  if not fileExists(path): return
  let document = parseJson(readFile(path))
  if document.kind != JObject or not document.hasKey("address") or
      document["address"].kind != JString or not document.hasKey("name") or
      document["name"].kind != JString:
    raise newException(ValueError, "Invalid saved audio output")
  result = AudioOutputSelection(address: document["address"].getStr(),
    name: document["name"].getStr())
  if result.address.len > 0:
    result.address = bluetoothAddress(result.address)

proc saveAudioOutput*(selection: AudioOutputSelection) =
  ## Atomically persist a speaker choice or validated Bluetooth device identity.
  let
    address = if selection.address.len == 0: "" else: bluetoothAddress(selection.address)
    path = audioOutputPath()
  createDir(path.parentDir)
  writeSave(path, $(%*{"address": address, "name": selection.name}))

proc openAudioRoute*(settings: Settings, selection: AudioOutputSelection,
    baseConfigPath: string): AudioRoute =
  ## Prepare playback configuration before any OpenAL playback or capture opens.
  result = AudioRoute(settings: settings, hadConfig: existsEnv("ALSOFT_CONF"),
    previousConfig: getEnv("ALSOFT_CONF"))
  if selection.address.len == 0: return
  let
    address = bluetoothAddress(selection.address)
    pcm = "bluealsa:DEV=" & address & ",PROFILE=a2dp"
    base = if baseConfigPath.len > 0: readFile(baseConfigPath) else: ""
    merged = base & "\n[general]\ndrivers = alsa\n\n[alsa]\ndevice = " & pcm & "\n"
    (file, path) = createTempFile("mono-retro-alsoft-", ".conf")
  try:
    try:
      file.write(merged)
      file.flushSaveFile()
    finally: file.close()
    putEnv("ALSOFT_CONF", path)
  except:
    removeFile(path)
    raise
  result.temporaryConfig = path
  result.headphones = true
  result.settings.audioDevice = pcm
  # Single-device static controls avoid invalid element pointers after disconnect.
  result.settings.volumeCard = BlueAlsaMixerPrefix & address & BlueAlsaMixerSuffix
  result.settings.volumeControls = @["A2DP"]
  result.settings.volumeInverted = false

proc openAudioRoute*(settings: Settings): AudioRoute =
  ## Select the saved output while retaining the existing configuration's capture settings.
  let
    selection = loadAudioOutput()
    configured = getEnv("ALSOFT_CONF")
    base = if configured.len > 0: configured
      elif settings.audioDevice != "default" and fileExists(BoardOpenAlConfig): BoardOpenAlConfig
      else: ""
  openAudioRoute(settings, selection, base)

proc close*(route: AudioRoute) =
  ## Restore the caller's environment after all playback and capture resources close.
  if route == nil or route.closed: return
  route.closed = true
  if route.temporaryConfig.len > 0:
    if route.hadConfig: putEnv("ALSOFT_CONF", route.previousConfig)
    else: delEnv("ALSOFT_CONF")
    removeFile(route.temporaryConfig)
