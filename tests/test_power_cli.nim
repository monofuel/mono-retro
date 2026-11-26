import
  std/[json, os, osproc, strutils, tempfiles]

proc main() =
  ## Exercise the installed command path without opening a menu or reading settings.
  doAssert paramCount() == 1
  let
    executable = absolutePath(paramStr(1))
    fixture = createTempDir("mono-retro-power-cli-", "")
    previousPath = getEnv("PATH")
    marker = fixture / "bus-read"
    busctl = fixture / "busctl"
    response = $(%*{"data": [{
      "Type": {"data": 3}, "State": {"data": 4}, "Percentage": {"data": 83.0},
      "IsPresent": {"data": true}, "PowerSupply": {"data": true}}]})
  defer:
    putEnv("PATH", previousPath)
    removeDir(fixture)
  writeFile(busctl, "#!/bin/sh\nprintf read >> " & quoteShell(marker) &
    "\nprintf '%s' " & quoteShell(response) & "\n")
  setFilePermissions(busctl, {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", fixture)
  let output = execCmdEx(quoteShell(executable) & " --power-status --device:generic" &
    " --library:" & quoteShell(fixture / "absent-library") &
    " --config:" & quoteShell(fixture / "absent-config.json"))
  doAssert output.exitCode == 0
  let reading = parseJson(output.output)
  doAssert reading["source"].getStr() == "UPS"
  doAssert reading["ups"].getBool() and reading["percent"].getInt() == 83
  doAssert reading["text"].getStr() == "UPS 83% · Plugged in"
  doAssert not dirExists(fixture / "absent-library")
  doAssert not fileExists(fixture / "absent-config.json")
  doAssert readFile(marker) == "read"
  removeFile(marker)
  let handheld = execCmdEx(quoteShell(executable) & " --power-status --device:rg-sp")
  doAssert handheld.exitCode == 0
  doAssert parseJson(handheld.output)["source"].getStr() == "axp2202-battery"
  doAssert not fileExists(marker), "An explicit handheld gauge must not query desktop UPower"

main()
