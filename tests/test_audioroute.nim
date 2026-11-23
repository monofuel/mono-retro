import
  std/[json, os, strutils, tempfiles, unittest],
  retro/[audioroute, settings, systemvolume]

const
  Address = "12:34:56:78:9A:BC"
  BaseConfig = """[general]
drivers = alsa
frequency = 48000
period_size = 512
[alsa]
device = mono_retro_ds_plus
capture = mono_retro_mic
mmap = false
[alsa/Board Microphone]
capture = hw:CARD=Mic,DEV=0
"""

proc getSectionValue(config, wantedSection, wantedKey: string): string =
  ## Read OpenAL's last-assignment syntax, whose unquoted values can contain colons.
  var section: string
  for raw in config.splitLines():
    let line = raw.strip()
    if line.startsWith("[") and line.endsWith("]"):
      section = line[1 .. ^2]
    elif section == wantedSection and '=' in line:
      let parts = line.split('=', 1)
      if parts[0].strip() == wantedKey:
        result = parts[1].strip()

suite "Next-launch audio routing":
  test "saved preference round trips with canonical address and safe JSON name":
    let
      directory = createTempDir("audio-preference-", "")
      oldHome = getEnv("XDG_CONFIG_HOME")
      hadHome = existsEnv("XDG_CONFIG_HOME")
    defer:
      if hadHome: putEnv("XDG_CONFIG_HOME", oldHome)
      else: delEnv("XDG_CONFIG_HOME")
      removeDir(directory)
    putEnv("XDG_CONFIG_HOME", directory)
    check loadAudioOutput() == AudioOutputSelection()
    saveAudioOutput(AudioOutputSelection(address: Address.toLowerAscii(), name: "A\n\"headset\""))
    check audioOutputPath() == directory / "mono-retro" / "audio-output.json"
    check loadAudioOutput() == AudioOutputSelection(address: Address, name: "A\n\"headset\"")
    let route = openAudioRoute(defaultSettings())
    check route.headphones
    check route.settings.audioDevice == "bluealsa:DEV=" & Address & ",PROFILE=a2dp"
    route.close()
    saveAudioOutput(AudioOutputSelection())
    check loadAudioOutput() == AudioOutputSelection()
    writeFile(audioOutputPath(), "{\"address\":\"not-a-device\",\"name\":\"Bad\"}")
    expect ValueError: discard loadAudioOutput()
    writeFile(audioOutputPath(), "{\"address\":17,\"name\":\"Bad\"}")
    expect ValueError: discard loadAudioOutput()

  test "speakers leave settings and environment untouched":
    let
      settings = parseSettings(@["--device:rg-ds-plus"])
      previous = getEnv("ALSOFT_CONF")
      existed = existsEnv("ALSOFT_CONF")
      route = openAudioRoute(settings, AudioOutputSelection(), "/missing/unread/config")
    check route.settings == settings
    check not route.headphones
    check getEnv("ALSOFT_CONF") == previous
    check existsEnv("ALSOFT_CONF") == existed
    route.close()
    route.close()

  test "Bluetooth changes playback and mixer but retains all capture and tuning":
    let
      directory = createTempDir("audio-route-", "")
      basePath = directory / "base.conf"
      previous = getEnv("ALSOFT_CONF")
      existed = existsEnv("ALSOFT_CONF")
    defer:
      if existed: putEnv("ALSOFT_CONF", previous)
      else: delEnv("ALSOFT_CONF")
      removeDir(directory)
    writeFile(basePath, BaseConfig)
    putEnv("ALSOFT_CONF", basePath)
    let
      settings = parseSettings(@["--device:rg-ds-plus"])
      selection = AudioOutputSelection(address: Address, name: "Headphones")
      route = openAudioRoute(settings, selection, basePath)
      temporary = getEnv("ALSOFT_CONF")
      merged = readFile(temporary)
    defer: route.close()
    check temporary != basePath
    check merged.getSectionValue("alsa", "device") == "bluealsa:DEV=" & Address & ",PROFILE=a2dp"
    check merged.getSectionValue("general", "drivers") == "alsa"
    check merged.getSectionValue("general", "frequency") == "48000"
    check merged.getSectionValue("general", "period_size") == "512"
    check merged.getSectionValue("alsa", "mmap") == "false"
    check merged.getSectionValue("alsa", "capture") == "mono_retro_mic"
    check merged.getSectionValue("alsa/Board Microphone", "capture") == "hw:CARD=Mic,DEV=0"
    check route.headphones
    check route.settings.volumeCard == BlueAlsaMixerPrefix & Address & BlueAlsaMixerSuffix
    check mixerDeviceName(route.settings.volumeCard) == route.settings.volumeCard
    check mixerDeviceName(settings.volumeCard) == "hw:" & settings.volumeCard
    check route.settings.volumeControls == @["A2DP"]
    check not route.settings.volumeInverted
    var restored = route.settings
    restored.audioDevice = settings.audioDevice
    restored.volumeCard = settings.volumeCard
    restored.volumeControls = settings.volumeControls
    restored.volumeInverted = settings.volumeInverted
    check restored == settings
    check readFile(basePath) == BaseConfig
    route.close()
    check not fileExists(temporary)
    check getEnv("ALSOFT_CONF") == basePath

  test "closing restores an absent environment variable":
    let
      previous = getEnv("ALSOFT_CONF")
      existed = existsEnv("ALSOFT_CONF")
    defer:
      if existed: putEnv("ALSOFT_CONF", previous)
      else: delEnv("ALSOFT_CONF")
    delEnv("ALSOFT_CONF")
    let route = openAudioRoute(defaultSettings(), AudioOutputSelection(address: Address), "")
    check existsEnv("ALSOFT_CONF")
    route.close()
    check not existsEnv("ALSOFT_CONF")

  test "invalid or wildcard identities never become ALSA configuration":
    for address in ["00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "12:34:56:78:9A:BC,PROFILE=sco",
        "12:34:56:78:9A:BC\n[alsa]\ncapture=bad", "12:34:56:78:9A:BG", "123456789ABC"]:
      expect ValueError:
        discard openAudioRoute(defaultSettings(), AudioOutputSelection(address: address), "")
    expect ValueError: discard mixerDeviceName("bluealsa:DEV=x")
    expect ValueError:
      discard mixerDeviceName(BlueAlsaMixerPrefix & Address & BlueAlsaMixerSuffix & ",SRV=other")

  test "speaker and headphone levels persist independently through the same controller":
    let
      directory = createTempDir("audio-levels-", "")
      basePath = directory / "volume.json"
      speakers = Settings(volumeCard: "Board", volumeControls: @["Speaker"])
      headphones = Settings(volumeCard: BlueAlsaMixerPrefix & Address & BlueAlsaMixerSuffix,
        volumeControls: @["A2DP"])
    defer: removeDir(directory)
    var raw = @[20'i64]
    let mixer = VolumeMixer(minimum: @[0'i64], maximum: @[100'i64],
      readRaw: proc(): seq[int64] = raw,
      writeRaw: proc(values: seq[int64]) = raw = values)
    let speakerVolume = newVolumeFromMixer(speakers, mixer, basePath)
    discard speakerVolume.adjust(5, 1)
    check speakerVolume.percent == 25
    raw = @[70'i64]
    let headphoneVolume = newVolumeFromMixer(headphones, mixer, basePath)
    headphoneVolume.updateButtons(false, true, 1)
    check headphoneVolume.percent == 75
    check parseJson(readFile(basePath))["percent"].getInt() == 25
    check parseJson(readFile(volumeStatePath(headphones, basePath)))["percent"].getInt() == 75
    let reopenedSpeakers = newVolumeFromMixer(speakers, mixer, basePath)
    check reopenedSpeakers.percent == 25
    let reopenedHeadphones = newVolumeFromMixer(headphones, mixer, basePath)
    check reopenedHeadphones.percent == 75
    speakerVolume.close()
    headphoneVolume.close()
    reopenedSpeakers.close()
    reopenedHeadphones.close()
