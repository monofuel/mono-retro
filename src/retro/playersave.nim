import
  std/[os, posix, tempfiles]

proc checkedFlush(file: File): cint {.importc: "fflush", header: "<stdio.h>".}
  ## Return the libc flush result instead of discarding delayed write errors.

proc flushSaveFile*(file: File) =
  ## Flush buffered bytes and check storage errors before publishing a save.
  if checkedFlush(file) != 0: raiseOSError(osLastError())
  if fsync(file.getFileHandle()) != 0: raiseOSError(osLastError())

proc writeSave*(path, contents: string) =
  ## Replace a save only after its complete new contents reach the filesystem.
  let (file, temporary) = createTempFile(".player-save-", ".tmp", path.parentDir)
  try:
    try:
      file.write(contents)
      file.flushSaveFile()
    finally:
      file.close()
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)
