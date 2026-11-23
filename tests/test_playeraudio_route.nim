import
  std/[os, strutils, unittest],
  openal,
  retro/[playbackcontext, playeraudio]

suite "Routed playback lifecycle":
  test "an unavailable selected output receives one exact open without fallback":
    var opens = 0
    let api = PlaybackContextApi(openDevice: proc(name: cstring): ALCdevice =
      check name == nil
      inc opens
      nil)
    expect IOError: discard openPlaybackContext(api)
    check opens == 1

  test "partial initialization releases the selected device":
    var
      opens, closes = 0
      contexts: seq[ALCcontext]
    let api = PlaybackContextApi(
      openDevice: proc(name: cstring): ALCdevice =
        check name == nil
        inc opens
        cast[ALCdevice](1),
      createContext: proc(device: ALCdevice): ALCcontext =
        check device == cast[ALCdevice](1)
        nil,
      closeDevice: proc(device: ALCdevice): bool =
        check device == cast[ALCdevice](1)
        inc closes
        true)
    expect IOError: discard openPlaybackContext(api)
    check opens == 1
    check closes == 1
    var completeApi = api
    completeApi.createContext = proc(device: ALCdevice): ALCcontext = cast[ALCcontext](2)
    completeApi.makeCurrent = proc(context: ALCcontext): bool =
      contexts.add context
      true
    completeApi.destroyContext = proc(context: ALCcontext) =
      check context == cast[ALCcontext](2)
    let playback = openPlaybackContext(completeApi)
    playback.close()
    playback.close()
    check opens == 2
    check closes == 2
    check contexts == @[cast[ALCcontext](2), nil]

  test "headphone loss mutes once and keeps accepting game frames without reconnecting":
    doAssert getEnv("ALSOFT_DRIVERS") == "null", "This test requires the silent null backend"
    var
      connected = true
      probes = 0
    let audio = newPlayerAudio(48000, headphones = true,
      connectionProbe = proc(): bool =
        inc probes
        connected)
    defer: audio.close()
    audio.submit(newSeq[int16](4800), 48000)
    check audio.bufferedFrames() > 0
    connected = false
    audio.pump()
    let
      firstError = audio.error
      firstProbes = probes
    check firstError.contains("Headphones disconnected")
    check audio.bufferedFrames() == 0
    connected = true
    for frame in 0 ..< 120:
      audio.pump()
      audio.submit(newSeq[int16](882), 44100)
      audio.reset()
    check audio.error == firstError
    check probes == firstProbes
    check audio.bufferedFrames() == 0
    audio.close()
