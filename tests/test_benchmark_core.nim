import
  std/[os, osproc, sha1, strutils, tempfiles],
  retro/[libretro, playercapture]

proc main() =
  ## Check option overrides, warmup accounting and failures against the real C ABI.
  let
    directory = createTempDir("benchmark-core-", "")
    rom = directory / "fixture.test"
    trace = directory / "trace"
    arguments = @[absolutePath("build/benchmark-core"),
      "--core:" & absolutePath("build/player-fixture.so"), "--rom:" & rom,
      "--save-dir:" & directory / "saves"]
  defer: removeDir(directory)
  writeFile(rom, "D")
  putEnv("MONO_RETRO_FIXTURE_TRACE", trace)
  defer: delEnv("MONO_RETRO_FIXTURE_TRACE")
  let run = execCmdEx(quoteShellCommand(arguments & @["--ds-layout:separate",
    "--frames:4", "--warmup:2", "--copy-video", "--copy-audio",
    "--option:fixture_option=second"]))
  doAssert run.exitCode == 0, run.output
  doAssert run.output.contains("Measured frames: 4; warmup: 2\n")
  doAssert run.output.contains("Option fixture_option=second\n")
  doAssert readFile(trace).count("input=0\n") == 6
  doAssert readFile(trace).contains("option_second=1\n")
  doAssert readFile(trace).endsWith("deinit=1\n")
  doAssert readFile(directory / "saves/fixture.srm").len == 16
  for option in ["--warmup:-1", "--frames:0", "--pause-ms:-1",
      "--option:invalid", "--ds-layout:invalid", "--option:missing=value"]:
    let failed = execCmdEx(quoteShellCommand(arguments & @[option]))
    doAssert failed.exitCode != 0, option
  let
    core = absolutePath("build/player-fixture.so")
    state = directory / "state.png"
    session = openCore(core, rom, directory / "state-source")
  session.step(0)
  writeFile(state, encodeScreenstatePng(session.image, session.exportState(),
    $secureHashFile(rom), $secureHashFile(core), 1, false))
  session.close()
  let restored = execCmdEx(quoteShellCommand(arguments & @["--frames:2", "--load-state:" & state]))
  doAssert restored.exitCode == 0, restored.output
  doAssert readFile(trace).contains("binary_state_loaded=1\n")
  writeFile(rom, "different ROM")
  let
    previousSave = readFile(directory / "saves/fixture.srm")
    rejected = execCmdEx(quoteShellCommand(arguments & @["--frames:2", "--load-state:" & state]))
  doAssert rejected.exitCode != 0
  doAssert readFile(directory / "saves/fixture.srm") == previousSave

when isMainModule:
  main()
