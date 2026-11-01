import
  std/[json, os, strutils, tempfiles, unittest],
  retro/[settings, systemvolume]

suite "System volume":
  test "inverted aw88166 mapping uses its discovered raw range":
    check rawToPercent(1023, 0, 1023, true) == 0
    check rawToPercent(0, 0, 1023, true) == 100
    check percentToRaw(0, 0, 1023, true) == 1023
    check percentToRaw(100, 0, 1023, true) == 0
    check percentToRaw(50, 0, 1023, true) in 511'i64..512'i64

  test "repeat has an edge, delay, cadence, and release reset":
    var state: RepeatState
    check state.repeatDue(true, 1)
    check not state.repeatDue(true, VolumeRepeatDelayNs)
    check state.repeatDue(true, VolumeRepeatDelayNs + 1)
    check not state.repeatDue(true, VolumeRepeatDelayNs + 2)
    check not state.repeatDue(false, VolumeRepeatDelayNs + 2)
    check state.repeatDue(true, VolumeRepeatDelayNs + 3)

  test "fake mixer writes both channels, reads back, and saves atomically":
    let directory = createTempDir("system-volume-", "")
    defer: removeDir(directory)
    let path = directory / "volume.json"
    var raws = @[1023'i64, 1023'i64]
    var writes = 0
    let mixer = VolumeMixer(minimum: @[0'i64, 0'i64], maximum: @[1023'i64, 1023'i64],
      readRaw: proc(): seq[int64] = raws,
      writeRaw: proc(values: seq[int64]) =
        inc writes
        raws = values)
    let settings = Settings(volumeInverted: true)
    let volume = newVolumeFromMixer(settings, mixer, path)
    check volume.percent == 0
    check volume.adjust(5, 1)
    check writes == 1
    check raws[0] == raws[1]
    check volume.percent == 5
    check volume.visible(1)
    check not volume.visible(VolumeToastDurationNs + 1)
    check parseJson(readFile(path))["percent"].getInt() == 5
    volume.close()

  test "an unconfigured profile has no controller":
    check openSystemVolume(Settings()) == nil

  test "opposed keys cancel and switching direction starts a fresh repeat":
    let directory = createTempDir("volume-buttons-", "")
    defer: removeDir(directory)
    var raws = @[500'i64, 500'i64]
    let mixer = VolumeMixer(minimum: @[0'i64, 0'i64], maximum: @[1000'i64, 1000'i64],
      readRaw: proc(): seq[int64] = raws,
      writeRaw: proc(values: seq[int64]) = raws = values)
    let volume = newVolumeFromMixer(Settings(volumeInverted: true), mixer, directory / "volume.json")
    volume.updateButtons(true, true, 1)
    check volume.percent == 50
    volume.updateButtons(true, false, 2)
    check volume.percent == 45
    volume.updateButtons(false, true, 3)
    check volume.percent == 50
    volume.updateButtons(false, false, 4)
    volume.updateButtons(true, false, 5)
    check volume.percent == 45
    volume.close()

  test "write failures preserve the saved setting":
    let directory = createTempDir("volume-failure-", "")
    defer: removeDir(directory)
    let path = directory / "volume.json"
    writeFile(path, "{\"percent\":40}")
    var raws = @[400'i64]
    var fail = false
    let mixer = VolumeMixer(minimum: @[0'i64], maximum: @[1000'i64],
      readRaw: proc(): seq[int64] = raws,
      writeRaw: proc(values: seq[int64]) =
        if fail: raise newException(IOError, "Synthetic mixer failure")
        raws = values)
    let volume = newVolumeFromMixer(Settings(), mixer, path)
    check volume.percent == 40
    fail = true
    check not volume.adjust(5, 1)
    check volume.error.contains("Synthetic mixer failure")
    check volume.percent == 40
    check parseJson(readFile(path))["percent"].getInt == 40
    volume.close()

  test "external changes are read back and persistence errors are surfaced":
    let directory = createTempDir("volume-readback-", "")
    defer: removeDir(directory)
    var raws = @[400'i64]
    let mixer = VolumeMixer(minimum: @[0'i64], maximum: @[1000'i64],
      readRaw: proc(): seq[int64] = raws,
      writeRaw: proc(values: seq[int64]) = raws = values)
    let volume = newVolumeFromMixer(Settings(), mixer, directory / "missing" / "volume.json")
    raws[0] = 700
    check volume.poll(1)
    check volume.percent == 70
    check volume.adjust(5, 2)
    check volume.percent == 75
    check volume.error.contains("Saving volume")
    volume.close()
