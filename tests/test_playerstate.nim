import
  std/[os, strutils, tempfiles],
  retro/libretro

proc main() =
  ## Exercise state import ordering, buffer reset and rejection through an actual C core.
  let
    directory = createTempDir("player-states-", "")
    rom = directory / "fixture.test"
    state = directory / "state with spaces.png"
    trace = directory / "trace"
    saves = directory / "saves"
    seed = repeat('\0', 4) & char(99) & repeat('\0', 11)
    core = absolutePath("build/player-fixture.so")
  defer:
    delEnv("MONO_RETRO_FIXTURE_TRACE")
    removeDir(directory)
  writeFile(rom, "E")
  writeFile(state, "fixture-state")
  createDir(saves)
  writeFile(saves / "fixture.srm", seed)
  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  let options = @[("decompbound_dual_screen", "enabled")]
  let session = openCore(core, rom, saves, captureAudio = true,
    options = options, statePath = state)
  session.step(256, PointerInput(x: 12, y: 34, pressed: true))
  doAssert readFile(trace).contains("loaded_byte=42\n")
  doAssert session.takeAudio().len > 0
  session.step(256, PointerInput(pressed: true))
  session.importStateData("fixture-state", "live drop")
  doAssert session.takeAudio().len == 0
  doAssert session.buttons == 0 and not session.pointerInput.pressed
  session.step(0)
  let count = readFile(trace).count("state_loaded=42\n")
  var rejected = false
  try: session.importStateData("bad-state", "bad drop")
  except IOError: rejected = true
  doAssert rejected
  session.step(0)
  doAssert readFile(trace).count("state_loaded=42\n") == count
  session.close()

  for path in [directory / "missing.png", directory / "empty.png", directory / "bad.png"]:
    if path.endsWith("empty.png"): writeFile(path, "")
    if path.endsWith("bad.png"): writeFile(path, "bad-state")
    writeFile(saves / "fixture.srm", seed)
    rejected = false
    try: discard openCore(core, rom, saves, options = options, statePath = path)
    except IOError: rejected = true
    doAssert rejected
    doAssert readFile(saves / "fixture.srm") == seed

  rejected = false
  try:
    discard openCore(absolutePath("build/player-fullpath.so"), rom, saves,
      options = options, statePath = state)
  except IOError: rejected = true
  doAssert rejected
  doAssert readFile(saves / "fixture.srm") == seed
  let normal = openCore(absolutePath("build/player-fullpath.so"), rom, saves, options = options)
  normal.step(0)
  normal.close()

main()
