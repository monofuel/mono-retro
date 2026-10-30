import
  std/[json, os, posix, tempfiles],
  ./ra_types

const
  RaConfigFilename* = ".mono-retro-ra.json"
  MaximumConfigBytes = 16 * 1024
  PrivatePermissions = {fpUserRead, fpUserWrite}
  PublicPermissions = {fpGroupRead, fpGroupWrite, fpGroupExec,
    fpOthersRead, fpOthersWrite, fpOthersExec}

proc resolveRaConfig*(overridePath = ""): string =
  ## Resolve explicit paths or the current account's home, including service contexts.
  if overridePath.len > 0: return absolutePath(overridePath)
  var homeDirectory = getEnv("HOME")
  if homeDirectory.len == 0:
    let account = getpwuid(geteuid())
    if account != nil and account.pw_dir != nil: homeDirectory = $account.pw_dir
  if homeDirectory.len == 0 or not homeDirectory.isAbsolute:
    raise newException(ValueError, "Cannot resolve home directory; use --ra-config:PATH")
  homeDirectory / RaConfigFilename

proc loadRaCredentials*(path: string): RaCredentials =
  ## Read a private login token without including file contents in diagnostics.
  if not fileExists(path): return
  if getFilePermissions(path) * PublicPermissions != {}:
    raise newException(ValueError, "RetroAchievements config must be owner-only: " & path)
  if getFileSize(path) notin 1'i64 .. MaximumConfigBytes.int64:
    raise newException(ValueError, "Invalid RetroAchievements config size: " & path)
  var document: JsonNode
  try:
    document = parseJson(readFile(path))
  except CatchableError:
    raise newException(ValueError, "Cannot parse RetroAchievements config: " & path)
  if document.kind != JObject or not document.hasKey("username") or
      not document.hasKey("token") or document["username"].kind != JString or
      document["token"].kind != JString:
    raise newException(ValueError, "Invalid RetroAchievements config fields: " & path)
  result = RaCredentials(username: document["username"].getStr,
    token: document["token"].getStr)
  if result.username.len == 0 or result.token.len == 0:
    raise newException(ValueError, "Empty RetroAchievements credentials: " & path)

proc saveRaCredentials*(path: string, credentials: RaCredentials) =
  ## Atomically replace the dotfile only after a complete private token is durable.
  if credentials.username.len == 0 or credentials.token.len == 0:
    raise newException(ValueError, "Cannot save empty RetroAchievements credentials")
  let (file, temporary) = createTempFile(".mono-retro-ra-", ".tmp", path.parentDir)
  try:
    try:
      setFilePermissions(temporary, PrivatePermissions)
      file.write((%*{"username": credentials.username, "token": credentials.token}).pretty)
      file.flushFile()
      if fsync(file.getFileHandle()) != 0: raiseOSError(osLastError())
    finally:
      file.close()
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc forgetRaCredentials*(path: string) =
  ## Forget the local token for subsequent player launches.
  if fileExists(path): removeFile(path)
