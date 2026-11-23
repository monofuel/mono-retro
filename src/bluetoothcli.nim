import
  std/[monotimes, os, parseopt, posix, strutils, times],
  retro/[bluetooth, bluezbus]

const
  MaxCommandBytes = 4096
  PollMs = 25
  Help = "Usage: mono-retro-bluetooth --state:ABSFILE | --once:status\n"

var
  terminating {.volatile.}: cint
  noFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc onTerminate(signal: cint) {.noconv.} =
  ## Ask the event loop to cancel owned operations and close its private bus.
  terminating = 1

proc publish*(path: string, content: string) =
  ## Atomically publish a complete private snapshot without following a temporary symlink.
  let
    temporary = path & "." & $getCurrentProcessId() & "." & $getMonoTime().ticks & ".tmp"
    descriptor = posix.open(temporary.cstring, O_WRONLY or O_CREAT or O_EXCL or noFollow,
      Mode(0o600))
  if descriptor < 0: raiseOSError(osLastError())
  var
    renamed = false
    closed = false
  try:
    var offset = 0
    while offset < content.len:
      let count = posix.write(descriptor, unsafeAddr content[offset], content.len - offset)
      if count < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError())
      if count == 0: raise newException(IOError, "Cannot write Bluetooth state")
      offset += int(count)
    let closeResult = posix.close(descriptor)
    closed = true
    if closeResult != 0: raiseOSError(osLastError())
    moveFile(temporary, path)
    renamed = true
  finally:
    if not closed and posix.close(descriptor) != 0: raiseOSError(osLastError())
    if not renamed:
      # This path handles both write and rename failures without exposing contents.
      if fileExists(temporary): removeFile(temporary)

proc runBluetooth*(arguments = commandLineParams()) =
  ## Run a private stdin-command session or print one read-only status snapshot.
  var
    statePath, once = ""
    session: BtSession
    state: BtState
    previous, input = ""
    latestRequest = 0'u64
    eof = false
  for kind, key, value in getopt(arguments):
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "state": statePath = value
      of "once": once = value
      of "help", "h":
        stdout.write Help
        return
      else: raise newException(ValueError, "Unknown Bluetooth option")
    of cmdArgument: raise newException(ValueError, "Bluetooth commands are accepted only on stdin")
    of cmdEnd: discard
  if once.len > 0:
    if once != "status" or statePath.len > 0:
      raise newException(ValueError, "Use --once:status for read-only status")
  elif statePath.len == 0 or not statePath.isAbsolute() or not dirExists(statePath.parentDir()):
    raise newException(ValueError, "--state must be an absolute file path in an existing directory")
  signal(SIGTERM, onTerminate)
  signal(SIGINT, onTerminate)
  try:
    try:
      session = openBtSession()
    except CatchableError as error:
      state.error = error.msg
    if once == "status":
      if session != nil:
        let deadline = getMonoTime() + initDuration(milliseconds = DefaultBtLimits.requestMs + 100)
        while not session.snapshotReady() and getMonoTime() < deadline and terminating == 0:
          session.pump(PollMs)
        state = session.state
      stdout.write state.stateJson() & "\n"
      return
    while terminating == 0 and not eof:
      if session != nil:
        try: session.pump()
        except CatchableError as error: session.state.error = error.msg
        state = session.state
      state.request = latestRequest
      let content = state.stateJson() & "\n"
      if content != previous:
        statePath.publish(content)
        previous = content
      var descriptor = TPollfd(fd: STDIN_FILENO, events: POLLIN)
      let polled = poll(addr descriptor, Tnfds(1), PollMs)
      if polled < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError())
      if polled == 0: continue
      if (descriptor.revents and (POLLIN or POLLHUP)) != 0:
        var bytes: array[MaxCommandBytes, char]
        let count = posix.read(STDIN_FILENO, addr bytes[0], bytes.len)
        if count < 0:
          if errno == EINTR: continue
          raiseOSError(osLastError())
        if count == 0:
          eof = true
          continue
        for index in 0 ..< int(count): input.add bytes[index]
        for index in 0 ..< bytes.len: bytes[index] = '\0'
        while '\n' in input:
          let separator = input.find('\n')
          var line = input[0 ..< separator]
          input.delete(0 .. separator)
          try:
            if line.len > MaxCommandBytes:
              raise newException(ValueError, "Bluetooth command exceeds size limit")
            var command = commandFromJson(line)
            latestRequest = command.request
            try:
              if session == nil and command.action == "status": session = openBtSession()
              if session != nil: session.submit(command)
              else: state.error = "Bluetooth system bus is unavailable"
            finally:
              for index in 0 ..< command.value.len: command.value[index] = '\0'
          except CatchableError as error:
            if session != nil: session.state.error = error.msg
            else: state.error = error.msg
          finally:
            for index in 0 ..< line.len: line[index] = '\0'
        if input.len > MaxCommandBytes:
          raise newException(ValueError, "Bluetooth command exceeds size limit")
      elif (descriptor.revents and (POLLERR or POLLNVAL)) != 0:
        raise newException(IOError, "Bluetooth command input failed")
  finally:
    for index in 0 ..< input.len: input[index] = '\0'
    if session != nil:
      session.close()
      state = session.state
    if statePath.len > 0:
      state.request = latestRequest
      state.busy = false
      state.discovering = false
      state.prompt = BtPrompt()
      statePath.publish(state.stateJson() & "\n")

when isMainModule:
  runBluetooth()
