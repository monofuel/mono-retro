## Native wpa_supplicant control socket and protected profile persistence.
##
## The control protocol is a Unix datagram exchange: the client binds its own
## socket, connects to `<control dir>/<interface>`, sends one command and reads
## one reply. Secrets therefore never appear in a process argument list.

import
  std/[monotimes, os, posix, strutils, tempfiles, times]

type
  WpaControl* = ref object
    socket: SocketHandle
    directory, serverPath: string
    timeoutMs: int
  PersistStep* = enum
    ## Points in `saveNetworkBlock` where tests may inject a failure.
    CopyStep, AppendStep, SyncStep, ReplaceStep
  PersistFault* = proc(step: PersistStep) {.closure.}

const
  DefaultControlDirectory* = "/run/wpa_supplicant"
  DefaultInterface* = "wlan0"
  ReplyBufferSize = 65536
  CopyBufferSize = 65536
  DefaultTimeoutMs = 5000
  EventSliceMs = 250
  InterfaceCharacters = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-', '.'}
  MaximumInterfaceLength = 15
  LockExclusive = 2.cint
  TempSuffix = ".mono-retro-XXXXXX"

proc flock(fd: cint, operation: cint): cint {.importc, header: "<sys/file.h>".}
proc rename(source, destination: cstring): cint {.importc, header: "<stdio.h>".}
var O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint

proc validateInterface*(name: string) =
  ## Accept only kernel interface names that cannot escape the control directory.
  if name.len == 0 or name.len > MaximumInterfaceLength or name in [".", ".."] or
      not name.allCharsInSet(InterfaceCharacters):
    raise newException(ValueError, "Invalid network interface name")

proc socketAddress(path: string): Sockaddr_un =
  ## Build a Unix socket address. Raises ValueError for paths that do not fit.
  if path.len >= result.sun_path.len: raise newException(ValueError, "Socket path is too long")
  result.sun_family = AF_UNIX.TSa_Family
  for index, character in path: result.sun_path[index] = character

proc interrupted(): bool =
  ## Report whether the last system call was interrupted by a signal.
  osLastError() == OSErrorCode(EINTR)

proc close*(control: WpaControl) =
  ## Close the socket and remove the private client endpoint.
  if control == nil: return
  if control.socket != InvalidSocket:
    discard posix.close(control.socket)
    control.socket = InvalidSocket
  if control.directory.len > 0:
    removeDir(control.directory)
    control.directory = ""

proc openEndpoint(control: WpaControl) =
  ## Bind a fresh private client socket and connect it to the daemon.
  control.directory = createTempDir("mono-retro-wpa-", "")
  try:
    setFilePermissions(control.directory, {fpUserRead, fpUserWrite, fpUserExec})
    control.socket = posix.socket(AF_UNIX, SOCK_DGRAM, 0)
    if control.socket == InvalidSocket: raiseOSError(osLastError())
    var local = socketAddress(control.directory / "client")
    if bindSocket(control.socket, cast[ptr SockAddr](addr local), sizeof(local).SockLen) != 0:
      raiseOSError(osLastError())
    var remote = socketAddress(control.serverPath)
    if connect(control.socket, cast[ptr SockAddr](addr remote), sizeof(remote).SockLen) != 0:
      raise newException(IOError, "Wi-Fi manager unavailable at " & control.serverPath & ": " &
        osErrorMsg(osLastError()))
  except CatchableError as error:
    control.close()
    raise error

proc openWpaControl*(interfaceName: string, controlDirectory = DefaultControlDirectory,
    timeoutMs = DefaultTimeoutMs): WpaControl =
  ## Connect to a running wpa_supplicant interface. Raises OSError or IOError
  ## when the daemon or its control socket is unavailable.
  validateInterface(interfaceName)
  result = WpaControl(socket: InvalidSocket, timeoutMs: timeoutMs,
    serverPath: controlDirectory / interfaceName)
  result.openEndpoint()

proc waitReadable(control: WpaControl, timeoutMs: int): bool =
  ## Wait until a datagram is ready. Signals do not shorten the wait, so a
  ## cancellation request cannot abandon a command that restores state.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0: return false
    var descriptor = TPollfd(fd: control.socket.cint, events: POLLIN)
    let ready = poll(addr descriptor, 1, remaining.cint)
    if ready > 0: return true
    if ready < 0 and not interrupted(): raiseOSError(osLastError(), "Wi-Fi manager reply")

proc receive(control: WpaControl): string =
  ## Read one datagram, retrying when a signal interrupts the call.
  result = newString(ReplyBufferSize)
  var received = recv(control.socket, addr result[0], ReplyBufferSize, 0)
  while received < 0 and interrupted():
    received = recv(control.socket, addr result[0], ReplyBufferSize, 0)
  if received < 0: raiseOSError(osLastError(), "Wi-Fi manager reply")
  result.setLen(received)

proc request*(control: WpaControl, command: string): string =
  ## Send one command and wait for its reply. Unsolicited event messages are
  ## skipped. After a timeout the client endpoint is replaced, so a late reply
  ## cannot be mistaken for the answer to a later command.
  if control.socket == InvalidSocket: control.openEndpoint()
  var sent = send(control.socket, command.cstring, command.len, 0)
  while sent < 0 and interrupted(): sent = send(control.socket, command.cstring, command.len, 0)
  if sent != command.len: raiseOSError(osLastError(), "Wi-Fi manager request")
  let deadline = getMonoTime() + initDuration(milliseconds = control.timeoutMs)
  while true:
    let remaining = int((deadline - getMonoTime()).inMilliseconds)
    if remaining <= 0 or not control.waitReadable(remaining):
      control.close()
      # The next request opens a fresh endpoint and reports any recovery error.
      raise newException(IOError, "Wi-Fi manager did not answer " & command.split(' ')[0])
    result = control.receive()
    if not result.startsWith('<'): break

proc attach*(control: WpaControl) =
  ## Subscribe this endpoint to daemon event messages.
  if control.request("ATTACH").strip() != "OK":
    raise newException(IOError, "Wi-Fi manager refused event monitoring")

proc waitForEvent*(control: WpaControl, names: openArray[string], timeoutMs: int,
    cancelled: proc(): bool): string =
  ## Wait for an attached event starting with one of `names` and return it
  ## without its priority prefix. Returns "" on timeout or cancellation.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while result.len == 0 and not cancelled():
    let remaining = int((deadline - getMonoTime()).inMilliseconds)
    if remaining <= 0: break
    if control.waitReadable(min(remaining, EventSliceMs)):
      var message = control.receive()
      if message.startsWith('<') and '>' in message: message = message[message.find('>') + 1 .. ^1]
      for name in names:
        if message.startsWith(name): result = message

proc discoverConfigPath*(interfaceName: string): string =
  ## Find the `-c` configuration of the running wpa_supplicant serving
  ## `interfaceName` by reading process command lines. Returns "" when unknown.
  for kind, entry in walkDir("/proc"):
    if kind != pcDir or not entry.extractFilename.allCharsInSet(Digits): continue
    try:
      if readFile(entry / "comm").strip() != "wpa_supplicant": continue
      var
        arguments = readFile(entry / "cmdline").split('\0')
        currentInterface = ""
        configs: seq[(string, string)]
        index = 0
      while index < arguments.len:
        let argument = arguments[index]
        for (flag, store) in [("-i", 0), ("-c", 1)]:
          if argument.startsWith(flag):
            var value = argument[flag.len .. ^1]
            if value.len == 0 and index + 1 < arguments.len:
              inc index
              value = arguments[index]
            if store == 0: currentInterface = value
            else: configs.add (currentInterface, value)
        if argument == "-N": currentInterface = ""
        inc index
      for (owner, path) in configs:
        if owner == interfaceName or (owner.len == 0 and configs.len == 1): return path
    except IOError, OSError:
      # Processes may exit while /proc is being enumerated.
      continue

proc writeAll(fd: cint, data: pointer, length: int) =
  ## Write a whole buffer, retrying short writes and signal interruptions.
  var written = 0
  while written < length:
    let count = posix.write(fd, cast[pointer](cast[int](data) + written), length - written)
    if count < 0 and interrupted(): continue
    if count <= 0: raiseOSError(osLastError(), "Wi-Fi configuration")
    written += count

proc sameTime(a, b: Timespec): bool =
  ## Compare two file timestamps exactly.
  a.tv_sec == b.tv_sec and a.tv_nsec == b.tv_nsec

proc saveNetworkBlock*(path, networkBlock: string, owner: Uid = 0, fault: PersistFault = nil) =
  ## Append a profile to a protected wpa_supplicant configuration by copying
  ## its bytes unparsed into a private same-directory file, appending, syncing
  ## and atomically replacing the original. The original must be a regular,
  ## singly linked, non-symlink file owned by `owner` with mode 0600. Writers
  ## coordinate through an exclusive lock on the directory. On any failure
  ## before the replace the original is untouched and the copy is removed.
  let directory = if path.parentDir.len > 0: path.parentDir else: "."
  let directoryFd = posix.open(directory.cstring, O_RDONLY or O_CLOEXEC)
  if directoryFd < 0: raiseOSError(osLastError(), "Wi-Fi configuration directory")
  defer: discard posix.close(directoryFd)
  var directoryInfo: Stat
  if fstat(directoryFd, directoryInfo) != 0 or not S_ISDIR(directoryInfo.st_mode):
    raise newException(IOError, "Wi-Fi configuration directory is not a directory")
  if flock(directoryFd, LockExclusive) != 0: raiseOSError(osLastError(), "Wi-Fi configuration lock")
  let source = posix.open(path.cstring, O_RDONLY or O_NOFOLLOW or O_CLOEXEC)
  if source < 0: raiseOSError(osLastError(), "Wi-Fi configuration")
  defer: discard posix.close(source)
  var info: Stat
  if fstat(source, info) != 0: raiseOSError(osLastError())
  if not S_ISREG(info.st_mode) or info.st_nlink != 1:
    raise newException(IOError, "Wi-Fi configuration is not a regular file")
  if info.st_uid != owner: raise newException(IOError, "Wi-Fi configuration has an unexpected owner")
  if (info.st_mode.int and 0o7777) != 0o600:
    raise newException(IOError, "Wi-Fi configuration must have mode 0600")
  var temporary = directory / ("." & path.extractFilename & TempSuffix)
  let fd = mkstemp(temporary.cstring)
  if fd < 0: raiseOSError(osLastError(), "Wi-Fi configuration copy")
  var
    open = true
    replaced = false
  try:
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    if fchmod(fd, Mode(0o600)) != 0: raiseOSError(osLastError())
    var copyInfo: Stat
    if fstat(fd, copyInfo) != 0: raiseOSError(osLastError())
    if (copyInfo.st_uid != info.st_uid or copyInfo.st_gid != info.st_gid) and
        fchown(fd, info.st_uid, info.st_gid) != 0:
      raiseOSError(osLastError(), "Wi-Fi configuration copy owner")
    var buffer = newString(CopyBufferSize)
    while true:
      let count = posix.read(source, addr buffer[0], CopyBufferSize)
      if count < 0 and interrupted(): continue
      if count < 0: raiseOSError(osLastError(), "Wi-Fi configuration")
      if count == 0: break
      fd.writeAll(addr buffer[0], count)
    if fault != nil: fault(CopyStep)
    if networkBlock.len > 0: fd.writeAll(unsafeAddr networkBlock[0], networkBlock.len)
    if fault != nil: fault(AppendStep)
    if fsync(fd) != 0: raiseOSError(osLastError(), "Wi-Fi configuration sync")
    if fault != nil: fault(SyncStep)
    open = false
    if posix.close(fd) != 0: raiseOSError(osLastError(), "Wi-Fi configuration copy")
    if fault != nil: fault(ReplaceStep)
    var current, now: Stat
    if lstat(path.cstring, current) != 0 or current.st_dev != info.st_dev or
        current.st_ino != info.st_ino or fstat(source, now) != 0 or now.st_size != info.st_size or
        not sameTime(now.st_mtim, info.st_mtim) or not sameTime(now.st_ctim, info.st_ctim):
      raise newException(IOError, "Wi-Fi configuration changed while saving; nothing was replaced")
    if rename(temporary.cstring, path.cstring) != 0:
      raiseOSError(osLastError(), "Wi-Fi configuration replace")
    replaced = true
  finally:
    if open: discard posix.close(fd)
    if not replaced and unlink(temporary.cstring) != 0 and osLastError() != OSErrorCode(ENOENT):
      raiseOSError(osLastError(), "Wi-Fi configuration copy cleanup")
  if fsync(directoryFd) != 0:
    raiseOSError(osLastError(), "Wi-Fi configuration was replaced but the directory sync failed")
