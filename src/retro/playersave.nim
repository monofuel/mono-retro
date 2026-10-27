import
  std/[os, posix, tempfiles]

proc writeSave*(path, contents: string) =
  ## Replace a save only after its complete new contents reach the filesystem.
  let (file, temporary) = createTempFile(".player-save-", ".tmp", path.parentDir)
  try:
    try:
      file.write(contents)
      file.flushFile()
      if fsync(file.getFileHandle()) != 0: raiseOSError(osLastError())
    finally:
      file.close()
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)
