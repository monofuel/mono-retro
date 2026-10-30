import
  std/monotimes,
  pixie,
  ./[libretro, playerprofile]

type
  CommandKind = enum
    Configure, Step, Save, ImportState, Stop
  Command = object
    kind: CommandKind
    core, rom, saves, state, contents, source: string
    options: seq[CoreOption]
    captureAudio: bool
    buttons: uint16
    pointerInput: PointerInput
    reusable: Image
  Reply = object
    error: string
    libraryName, libraryVersion, savePath: string
    av: AvInfo
    image: Image
    audio: seq[int16]
    frames, videoFrames, audioFrames: uint64
    shutdown: bool
    coreTicks: int64
  Mailbox = object
    commands: Channel[Command]
    replies: Channel[Reply]
  CoreWorker* = ref object
    mailbox: ptr Mailbox
    thread: Thread[ptr Mailbox]
    pending, ready: bool
    reply: Reply
    reusable: Image
    audio: seq[int16]
    libraryName*, libraryVersion*, savePath*: string
    av*: AvInfo
    image*: Image
    frames*, videoFrames*, audioFrames*: uint64
    shutdown*: bool
    imageChanged*: bool ## Fresh image; exact change detection is opt-in.

proc owned(value: string): string =
  ## Copy a string before transferring ownership to another thread.
  result = newString(value.len)
  if value.len > 0: copyMem(addr result[0], unsafeAddr value[0], value.len)

proc emulate(mailbox: ptr Mailbox) {.thread.} =
  ## Own all core calls and callbacks on one thread; transfer unique frame buffers.
  # Libretro uses process-global callbacks. Only this thread accesses its session.
  {.cast(gcsafe).}:
    var session: CoreSession
    try:
      let config = mailbox.commands.recv()
      session = openCore(config.core, config.rom, config.saves,
        captureAudio = config.captureAudio, options = config.options,
        statePath = config.state)
      mailbox.replies.send(Reply(libraryName: $session.info.libraryName,
        libraryVersion: $session.info.libraryVersion, savePath: owned(session.savePath),
        av: session.av))
    except CatchableError as error:
      mailbox.replies.send(Reply(error: "Core worker: " & error.msg & "\n" & error.getStackTrace()))
      return
    while true:
      var
        command = mailbox.commands.recv()
        reply: Reply
      try:
        case command.kind
        of Step:
          if command.reusable != nil: session.image = move(command.reusable)
          let
            previousVideoFrames = session.videoFrames
            started = getMonoTime().ticks
          session.step(command.buttons, command.pointerInput)
          reply.coreTicks = getMonoTime().ticks - started
          reply.av = session.av
          reply.frames = session.frames
          reply.videoFrames = session.videoFrames
          reply.audioFrames = session.audioFrames
          reply.shutdown = session.shutdown
          # A duplicate callback must retain the displayed frame, not publish the
          # older recycled buffer. Keep that buffer here for the next fresh frame.
          if session.videoFrames != previousVideoFrames: reply.image = move(session.image)
          reply.audio = session.takeAudio()
        of Save: session.save()
        of ImportState:
          session.importStateData(command.contents, command.source)
          reply.av = session.av
        of Stop: session.close()
        of Configure: raise newException(ValueError, "Core already configured")
      except CatchableError as error:
        reply.error = "Core worker: " & error.msg & "\n" & error.getStackTrace()
      mailbox.replies.send(move(reply))
      if command.kind == Stop: break

proc checked(reply: Reply) =
  ## Propagate core errors with the originating worker's stack trace.
  if reply.error.len > 0: raise newException(IOError, reply.error)

proc finishPending(worker: CoreWorker) =
  ## Retain an in-flight frame before issuing a serialized control operation.
  if worker.pending:
    worker.reply = worker.mailbox.replies.recv()
    worker.pending = false
    worker.ready = true

proc request(worker: CoreWorker, command: Command): Reply =
  ## Serialize state/save operations after any in-flight core call.
  worker.finishPending()
  worker.mailbox.commands.send(command)
  result = worker.mailbox.replies.recv()
  result.checked()

proc close*(worker: CoreWorker) =
  ## Finish outstanding work, save and unload on the core thread, then join it.
  if worker == nil or worker.mailbox == nil: return
  worker.finishPending()
  worker.mailbox.commands.send(Command(kind: Stop))
  let reply = worker.mailbox.replies.recv()
  joinThread(worker.thread)
  worker.mailbox.commands.close()
  worker.mailbox.replies.close()
  deallocShared(worker.mailbox)
  worker.mailbox = nil
  let pendingError = worker.reply.error
  worker.reply = Reply()
  worker.reusable = nil
  worker.image = nil
  worker.audio = @[]
  if pendingError.len > 0:
    raise newException(IOError, pendingError & reply.error)
  reply.checked()

proc openCoreWorker*(corePath, romPath, saveDirectory: string, captureAudio = false,
    options: seq[CoreOption] = @[], statePath = ""): CoreWorker =
  ## Load a software core on its dedicated thread with one bounded frame in flight.
  result = CoreWorker(mailbox: cast[ptr Mailbox](allocShared0(sizeof(Mailbox))))
  result.mailbox.commands.open(1)
  result.mailbox.replies.open(1)
  createThread(result.thread, emulate, result.mailbox)
  var config = Command(kind: Configure, core: owned(corePath), rom: owned(romPath),
    saves: owned(saveDirectory), state: owned(statePath), captureAudio: captureAudio)
  for option in options: config.options.add((owned(option.key), owned(option.value)))
  result.mailbox.commands.send(move(config))
  let reply = result.mailbox.replies.recv()
  if reply.error.len > 0:
    joinThread(result.thread)
    result.mailbox.commands.close()
    result.mailbox.replies.close()
    deallocShared(result.mailbox)
    result.mailbox = nil
    reply.checked()
  result.libraryName = reply.libraryName
  result.libraryVersion = reply.libraryVersion
  result.savePath = reply.savePath
  result.av = reply.av

proc prefetch*(worker: CoreWorker, buttons: uint16, pointerInput = PointerInput()) =
  ## Start the next frame while the main thread presents the current one.
  if worker.pending or worker.ready: return
  worker.mailbox.commands.send(Command(kind: Step, buttons: buttons,
    pointerInput: pointerInput, reusable: move(worker.reusable)))
  worker.pending = true

proc step*(worker: CoreWorker, buttons: uint16, pointerInput = PointerInput(),
    compareVideo = false) =
  ## Consume one frame; optionally compare video before recycling its old storage.
  worker.prefetch(buttons, pointerInput)
  worker.finishPending()
  var reply = move(worker.reply)
  worker.ready = false
  reply.checked()
  worker.imageChanged = false
  if reply.image != nil:
    worker.imageChanged = not compareVideo or worker.image == nil or
      worker.image.width != reply.image.width or worker.image.height != reply.image.height or
      not equalMem(unsafeAddr worker.image.data[0], unsafeAddr reply.image.data[0],
        reply.image.data.len * sizeof(ColorRGBX))
    worker.reusable = move(worker.image)
    worker.image = move(reply.image)
  worker.audio = move(reply.audio)
  worker.av = reply.av
  worker.frames = reply.frames
  worker.videoFrames = reply.videoFrames
  worker.audioFrames = reply.audioFrames
  worker.shutdown = reply.shutdown
  recordTiming(CoreWork, reply.coreTicks)

proc takeAudio*(worker: CoreWorker): seq[int16] =
  ## Transfer the last completed frame's PCM to the audio owner.
  result = move(worker.audio)

proc save*(worker: CoreWorker) =
  ## Persist SRAM on the core thread without discarding a prefetched frame.
  discard worker.request(Command(kind: Save))

proc importStateData*(worker: CoreWorker, contents, source: string) =
  ## Serialize a state import; reject errors without losing the prior ready frame.
  let reply = worker.request(Command(kind: ImportState, contents: owned(contents),
    source: owned(source)))
  worker.reply = Reply()
  worker.ready = false
  worker.audio = @[]
  worker.av = reply.av

proc pause*(worker: CoreWorker) =
  ## Quiesce emulation and discard queued PCM before a focus pause.
  worker.finishPending()
  worker.reply.checked()
  worker.reply.audio = @[]
  worker.audio = @[]
