import
  std/[os, osproc, strutils, tempfiles]

const GameName = "LOST_IN_BLUE_ASKEA4_00"

let
  root = createTempDir("mono-retro-copy-", "")
  source = root / "archive"
  target = root / "work"
  originalSave = repeat('s', 8192)
  tool = absolutePath("build/prepare-lost-in-blue")
createDir(source)
writeFile(source / GameName & ".nds", "synthetic ROM")
writeFile(source / GameName & ".sav", originalSave)
try:
  let command = quoteShell(tool) & " " & quoteShell(source) & " " & quoteShell(target)
  doAssert execCmdEx(command).exitCode == 0
  let save = target / "saves" / GameName & ".srm"
  doAssert readFile(save) == originalSave
  doAssert getFileInfo(save).id != getFileInfo(source / GameName & ".sav").id
  doAssert getFileInfo(target / GameName & ".nds").id != getFileInfo(source / GameName & ".nds").id
  writeFile(save, "test progress")
  doAssert execCmdEx(command).exitCode == 0
  doAssert readFile(save) == "test progress"
  doAssert readFile(source / GameName & ".sav") == originalSave
  doAssert execCmdEx(quoteShell(tool) & " " & quoteShell(source) & " " & quoteShell(source)).exitCode != 0
  removeFile(save)
  createSymlink(source / GameName & ".sav", save)
  doAssert execCmdEx(command).exitCode != 0
  doAssert readFile(source / GameName & ".sav") == originalSave
  removeFile(save)
  createHardlink(source / GameName & ".sav", save)
  doAssert execCmdEx(command).exitCode != 0
  doAssert readFile(source / GameName & ".sav") == originalSave
finally:
  removeDir(root)
