import
  std/[monotimes, os, strutils, tempfiles, times],
  retro/[audio]

proc waitForTone(audio: AudioTest, count: int) =
  let started = getMonoTime()
  while audio.completed < count:
    audio.poll()
    doAssert (getMonoTime() - started).inSeconds < 5
    sleep(10)

let
  directory = createTempDir("mono-retro-audio-", "")
  output = directory / "stream.raw"
  config = directory / "alsa.conf"
  originalConfig = getEnv("ALSA_CONFIG_PATH")
writeFile(config, "pcm.capture { type file slave.pcm { type null } file \"" &
  output & "\" format raw }\n")
putEnv("ALSA_CONFIG_PATH", config)
try:
  let audio = AudioTest(device: "capture")
  try:
    audio.poll()
    doAssert not fileExists(output)
    audio.play()
    audio.play()
    audio.waitForTone(1)
    sleep(200)
    audio.poll()
    doAssert audio.completed == 1
    let firstBytes = getFileSize(output)
    doAssert firstBytes >= toneWave().len - 44
    sleep(120)
    doAssert getFileSize(output) > firstBytes
    audio.play()
    audio.waitForTone(2)
  finally:
    audio.close()
  audio.close()
  let
    captured = readFile(output)
    wave = toneWave()[44..^1]
    firstTone = captured.find(wave)
    secondTone = captured.find(wave, firstTone + wave.len)
  doAssert firstTone >= 0
  doAssert secondTone >= firstTone + wave.len
  for index in firstTone + wave.len ..< secondTone:
    doAssert captured[index] == '\0'
  for index in secondTone + wave.len ..< captured.len:
    doAssert captured[index] == '\0'
  let invalid = AudioTest(device: "mono_retro_missing_pcm")
  var rejected = false
  try:
    invalid.play()
    invalid.waitForTone(1)
  except IOError:
    rejected = true
  finally:
    try:
      invalid.close()
    except IOError:
      rejected = true
  doAssert rejected
finally:
  if originalConfig.len == 0:
    delEnv("ALSA_CONFIG_PATH")
  else:
    putEnv("ALSA_CONFIG_PATH", originalConfig)
  for path in [output, config]:
    if fileExists(path):
      removeFile(path)
  removeDir(directory)
