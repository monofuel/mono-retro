import
  std/[os, osproc, streams, strutils, tempfiles]

proc main() =
  ## Check one-argument paths and per-game save routing without opening a real emulator.
  let
    root = createTempDir("retroarch-launcher-", "")
    binary = root / "retroarch"
    marker = root / "arguments"
    core = root / "mupen core.so"
    rom = root / "Majora's Mask (USA).z64"
    saves = root / "saves with spaces"
    screenshots = root / "screenshots"
    originalPath = getEnv("PATH")
  defer:
    putEnv("PATH", originalPath)
    delEnv("MONO_RETRO_ARGV_MARKER")
    removeDir(root)
  writeFile(binary, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$MONO_RETRO_ARGV_MARKER\"\n")
  setFilePermissions(binary, {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(core, "synthetic core")
  writeFile(rom, "synthetic game")
  putEnv("PATH", root & ":" & originalPath)
  putEnv("MONO_RETRO_ARGV_MARKER", marker)
  let process = startProcess(findExe("bash"), args = [absolutePath("tools/retroarch-player.sh"),
    "--frontend:retroarch", "--core:" & core, "--rom:" & rom, "--save-dir:" & saves,
    "--screenstate-dir:" & screenshots], options = {poStdErrToStdOut})
  let output = process.outputStream.readAll()
  doAssert process.waitForExit() == 0, output
  process.close()
  doAssert readFile(marker).splitLines() == @["--config", saves / "retroarch-launch.cfg",
    "-L", core, rom, ""]
  let config = readFile(saves / "retroarch-launch.cfg")
  doAssert "savefile_directory = \"" & saves & "\"" in config
  doAssert "savestate_directory = \"" & saves / "states" & "\"" in config
  doAssert "screenshot_directory = \"" & screenshots & "\"" in config
  doAssert "config_save_on_exit = \"false\"" in config
  doAssert dirExists(saves / "states") and dirExists(screenshots)
  doAssert readFile(rom) == "synthetic game"

when isMainModule:
  main()
