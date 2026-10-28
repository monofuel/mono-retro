import
  std/[os, strutils]

const
  GameName = "LOST_IN_BLUE_ASKEA4_00"
  SaveBytes = 8192

proc copyOriginal(source, target: string, permissions: set[FilePermission],
    preserveExisting: bool) =
  ## Make a real, verified copy and never replace an existing working save.
  if symlinkExists(target) or dirExists(target):
    raise newException(IOError, "Working file must not be a link or directory: " & target)
  if fileExists(target):
    if getFileInfo(source).id == getFileInfo(target).id:
      raise newException(IOError, "Working file must not alias the archive: " & target)
    if not preserveExisting and readFile(source) != readFile(target):
      raise newException(IOError, "Working ROM differs from the original: " & target)
    return
  copyFile(source, target)
  setFilePermissions(target, permissions)
  if readFile(source) != readFile(target):
    raise newException(IOError, "Copy verification failed: " & target)

proc main() =
  ## Seed a disposable desktop test directory from the preserved cartridge pair.
  if paramCount() != 2:
    raise newException(ValueError, "Usage: prepare-lost-in-blue SOURCE_DIRECTORY WORK_DIRECTORY")
  let
    source = absolutePath(paramStr(1)).normalizedPath
    target = absolutePath(paramStr(2)).normalizedPath
    rom = source / GameName & ".nds"
    save = source / GameName & ".sav"
  if target == source or target.startsWith(source & DirSep):
    raise newException(ValueError, "Work directory must be outside the archive")
  if not fileExists(rom) or not fileExists(save) or getFileSize(save) != SaveBytes:
    raise newException(IOError, "Expected Lost in Blue ROM and original 8192-byte .sav")
  if symlinkExists(target) or symlinkExists(target / "saves"):
    raise newException(IOError, "Work directories must not be symbolic links")
  createDir(target / "saves")
  copyOriginal(rom, target / GameName & ".nds", {fpUserRead}, false)
  copyOriginal(save, target / "saves" / GameName & ".srm", {fpUserRead, fpUserWrite}, true)

when isMainModule:
  main()
