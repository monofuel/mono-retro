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

proc writeNewSave*(path, contents: string): string =
  ## Write a new private capture, choosing a suffix without overwriting existing files.
  let parts = path.splitFile()
  var
    suffix = 1
    descriptor: cint
  while true:
    result = if suffix == 1: path
      else: parts.dir / (parts.name & "_" & $suffix & parts.ext)
    descriptor = posix.open(result.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
    if descriptor >= 0: break
    let error = osLastError()
    if error != OSErrorCode(EEXIST): raiseOSError(error, result)
    inc suffix
  var file: File
  if not file.open(descriptor, fmWrite):
    let error = osLastError()
    discard posix.close(descriptor)
    raiseOSError(error, result)
  try:
    file.write(contents)
    file.flushSaveFile()
  finally:
    file.close()
