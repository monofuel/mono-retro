import
  std/[monotimes, os, sha1],
  pixie,
  ./[libretro, playercapture, playermicrophone, playerprofile, playerslots, ra_client, ra_types]

when defined(raTesting):
  import ./ra_http

  type WorkerRaHttpTestHandler* = proc(request: RaHttpRequest): RaHttpResponse {.nimcall.}

  var workerRaHttpTestHandler: WorkerRaHttpTestHandler

type
  CommandKind = enum
    Configure, Step, Save, ImportState, ExportState, Capture, SaveSlot, IdleAchievements, Pause, Stop
  Command = object
    kind: CommandKind
    core, rom, saves, state, contents, source: string
    raConfigPath: string
    captureRoot, screenstateDirectory, replayPath: string
    options: seq[CoreOption]
    captureAudio, achievementsEnabled, withList, withState: bool
    microphoneEnabled: bool
    microphoneGainDb: int
    microphoneFactory: MicrophoneFactory
    buttons: uint16
    slot: int
    pointerInput: PointerInput
    reusable: Image
    when defined(raTesting):
      raHttpTestHandler: WorkerRaHttpTestHandler
  Reply = object
    error: string
    libraryName, libraryVersion, savePath: string
    captureDirectory: string
    contents: string
    stateExport, stateImport: bool
    stateImported: bool
    av: AvInfo
    image: Image
    audio: seq[int16]
    frames, videoFrames, audioFrames: uint64
    shutdown: bool
    coreTicks: int64
    raPresent: bool
    raSnapshot: RaSnapshot
    raNotices: seq[RaNotice]
  Mailbox = object
    commands: Channel[Command]
    replies: Channel[Reply]
  CoreWorker* = ref object
    mailbox: ptr Mailbox
    thread: Thread[ptr Mailbox]
    pending, ready: bool
    fatalError: string
    reply: Reply
    reusable: Image
    audio: seq[int16]
    libraryName*, libraryVersion*, savePath*: string
    captureDirectory*: string
    stateExport*: bool
    stateImport*: bool
    av*: AvInfo
    image*: Image
    frames*, videoFrames*, audioFrames*: uint64
    shutdown*: bool
    imageChanged*: bool ## Fresh image; exact change detection is opt-in.
    raSnapshot*: RaSnapshot
    raNotices: seq[RaNotice]

proc owned(value: string): string =
  ## Copy a string before transferring ownership to another thread.
  result = newString(value.len)
  if value.len > 0: copyMem(addr result[0], unsafeAddr value[0], value.len)

when defined(raTesting):
  proc setWorkerRaHttpTestHandler*(handler: WorkerRaHttpTestHandler) =
    ## Select a stateless synthetic transport to install on the next core owner thread.
    workerRaHttpTestHandler = handler

proc captureAchievements(reply: var Reply, runtime: RaRuntime, withList = false) =
  ## Publish owned achievement values without transferring any SDK or RAM pointers.
  reply.raPresent = true
  reply.raSnapshot = ownedSnapshot(runtime.snapshot(withList))
  for notice in runtime.takeNotices():
    reply.raNotices.add(RaNotice(title: owned(notice.title),
      description: owned(notice.description), points: notice.points))

proc closeOwned(runtime: var RaRuntime, session: CoreSession, microphone: PlayerMicrophone) =
  ## Settle achievement callbacks before unloading the memory they can inspect.
  try:
    runtime.close()
  finally:
    runtime = nil
    try: session.close()
    finally: microphone.close()

proc withoutMicrophoneOptions(options: seq[CoreOption]): seq[CoreOption] =
  ## Compare replay controls independently of saved microphone policy.
  for option in options:
    if option.key notin ["melonds_mic_input", "melonds_mic_input_active"]:
      result.add(option)

proc emulate(mailbox: ptr Mailbox) {.thread.} =
  ## Own all core calls and callbacks on one thread; transfer unique frame buffers.
  # Libretro uses process-global callbacks. Only this thread accesses its session.
  {.cast(gcsafe).}:
    var
      session: CoreSession
      microphone: PlayerMicrophone
      runtime: RaRuntime
      writer: CaptureWriter
      replay: ReplayRecording
      replaying = false
      replayCursor = 0
      romHash, coreHash: string
      stateExport = false
      slots: StateStore
    try:
      let config = mailbox.commands.recv()
      when defined(raTesting):
        setRaHttpTestHandler(config.raHttpTestHandler)
      romHash = $secureHashFile(config.rom)
      coreHash = $secureHashFile(config.core)
      var
        initialState: string
        coreOptions = config.options
      if config.replayPath.len > 0:
        replay = readReplay(config.replayPath)
        replaying = true
        if replay.romHash != romHash or replay.coreHash != coreHash:
          raise newException(IOError, "Replay ROM or core build does not match")
        if withoutMicrophoneOptions(replay.options) != withoutMicrophoneOptions(config.options):
          raise newException(IOError, "Replay requires the same core options")
        coreOptions = replay.options
        initialState = replay.checkpoint
      elif config.state.len > 0:
        if getFileSize(config.state) > 64 * 1024 * 1024:
          raise newException(IOError, "State file exceeds supported size")
        initialState = unwrapScreenstate(readFile(config.state), romHash, coreHash)
      let microphoneEnabled = config.microphoneEnabled and not replaying
      if microphoneEnabled:
        microphone = newPlayerMicrophone(config.microphoneFactory, config.microphoneGainDb)
      let defaults: seq[CoreOption] = @[
        ("melonds_mic_input", if microphoneEnabled: "microphone" else: "silence"),
        ("melonds_mic_input_active", "always")]
      session = openCore(config.core, config.rom, config.saves,
        captureAudio = config.captureAudio, options = coreOptions,
        statePath = config.state, stateData = initialState, defaultOptions = defaults,
        microphoneInterface = (if microphone == nil: nil else: addr microphone.api))
      stateExport = session.stateSize() > 0
      slots = newStateStore(config.saves, config.rom, config.core, config.captureRoot,
        config.screenstateDirectory)
      if config.captureRoot.len > 0:
        writer = openCaptureWriter(config.captureRoot, config.rom, config.core,
          $session.info.libraryName, $session.info.libraryVersion, coreOptions,
          config.screenstateDirectory)
        if session.microphoneRequested: writer.disableReplay()
        if stateExport and writer.replayEnabled(): writer.beginSegment(session.exportState())
      runtime = newRaRuntime(config.raConfigPath, config.achievementsEnabled,
        session.supportsAchievements(), session.originalRomPath(), session.originalRomData(),
        session.achievementMemoryProvider())
      var reply = Reply(libraryName: $session.info.libraryName,
        libraryVersion: $session.info.libraryVersion, savePath: owned(session.savePath),
        av: session.av, stateExport: stateExport, stateImport: session.canImportState(),
        captureDirectory: (if writer != nil: owned(writer.directory) else: ""),
        shutdown: replaying and replay.inputs.len == 0)
      reply.captureAchievements(runtime)
      mailbox.replies.send(move(reply))
    except CatchableError as error:
      var message = "Core worker: " & error.msg & "\n" & error.getStackTrace()
      try:
        try:
          if writer != nil: writer.close()
        finally: closeOwned(runtime, session, microphone)
      except CatchableError as cleanupError:
        message.add("\nCore cleanup: " & cleanupError.msg)
      mailbox.replies.send(Reply(error: message))
      return
    while true:
      var
        command = mailbox.commands.recv()
        reply: Reply
      try:
        case command.kind
        of Step:
          microphone.resume()
          if command.reusable != nil: session.image = move(command.reusable)
          let
            previousVideoFrames = session.videoFrames
            started = getMonoTime().ticks
          let input = if replaying: replay.inputs[replayCursor]
            else: ReplayInput(buttons: command.buttons, pointerInput: command.pointerInput)
          if writer != nil and stateExport: writer.recordInput(input.buttons, input.pointerInput)
          try: session.step(input.buttons, input.pointerInput)
          finally:
            if writer != nil and session.microphoneRequested: writer.disableReplay()
          if replaying: inc replayCursor
          runtime.frame()
          reply.coreTicks = getMonoTime().ticks - started
          reply.av = session.av
          reply.frames = session.frames
          reply.videoFrames = session.videoFrames
          reply.audioFrames = session.audioFrames
          reply.shutdown = session.shutdown or (replaying and replayCursor >= replay.inputs.len)
          # A duplicate callback must retain the displayed frame, not publish the
          # older recycled buffer. Keep that buffer here for the next fresh frame.
          if session.videoFrames != previousVideoFrames: reply.image = move(session.image)
          reply.audio = session.takeAudio()
        of Save: session.save()
        of ImportState:
          if replaying: raise newException(IOError, "State drops are disabled during replay")
          session.importStateData(unwrapScreenstate(command.contents, romHash, coreHash), command.source)
          reply.stateImported = true
          microphone.reset()
          reply.av = session.av
          if writer != nil and session.microphoneRequested: writer.disableReplay()
          if writer.replayEnabled() and stateExport: writer.beginSegment(session.exportState())
          runtime.resetProgress()
          runtime.refreshMemory()
        of ExportState: reply.contents = session.exportState()
        of Capture:
          if writer == nil: raise newException(IOError, "Captures are disabled")
          if command.withState and not stateExport:
            raise newException(IOError, "Core does not support screenstates")
          writer.capture(command.reusable,
            (if command.withState: session.exportState() else: ""), command.source)
        of SaveSlot:
          if replaying: raise newException(IOError, "Save slots are disabled during replay")
          slots.saveSlot(command.slot, command.reusable, session.exportState())
        of IdleAchievements: runtime.idle()
        of Pause: microphone.suspend()
        of Stop:
          try:
            if writer != nil:
              try:
                if command.reusable != nil:
                  writer.capture(command.reusable,
                    (if stateExport: session.exportState() else: ""), "exit")
              finally: writer.close()
          finally: closeOwned(runtime, session, microphone)
        of Configure: raise newException(ValueError, "Core already configured")
        if command.kind != Stop:
          reply.captureAchievements(runtime, command.withList)
      except CatchableError as error:
        if command.kind == ImportState and reply.stateImported:
          reply.shutdown = true
          reply.error = "State restored, but recording or achievement reset failed: "
        else: reply.error = "Core worker: "
        reply.error.add(error.msg & "\n" & error.getStackTrace())
      mailbox.replies.send(move(reply))
      if command.kind == Stop: break

proc checked(reply: Reply) =
  ## Propagate core errors with the originating worker's stack trace.
  if reply.error.len > 0: raise newException(IOError, reply.error)

proc acceptAchievements(worker: CoreWorker, reply: var Reply) =
  ## Surface prefetched achievement events once while retaining its frame and audio.
  if reply.raPresent:
    worker.raSnapshot = move(reply.raSnapshot)
    reply.raPresent = false
  for notice in reply.raNotices.mitems:
    worker.raNotices.add(move(notice))
  reply.raNotices.setLen(0)

proc finishPending(worker: CoreWorker) =
  ## Retain an in-flight frame before issuing a serialized control operation.
  if worker.pending:
    worker.reply = worker.mailbox.replies.recv()
    worker.acceptAchievements(worker.reply)
    worker.pending = false
    worker.ready = true

proc request(worker: CoreWorker, command: Command, checkResult = true): Reply =
  ## Serialize state/save operations after any in-flight core call.
  worker.finishPending()
  worker.mailbox.commands.send(command)
  result = worker.mailbox.replies.recv()
  worker.acceptAchievements(result)
  if checkResult: result.checked()

proc snapshotImage(worker: CoreWorker): Image =
  ## Copy the image belonging to the latest completed frame while the worker is idle.
  let image = if worker.ready and worker.reply.image != nil: worker.reply.image
    else: worker.image
  if image != nil: result = image.copy()

proc close*(worker: CoreWorker) =
  ## Finish outstanding work, save and unload on the core thread, then join it.
  if worker == nil or worker.mailbox == nil: return
  worker.finishPending()
  worker.mailbox.commands.send(Command(kind: Stop,
    reusable: (if worker.reply.error.len == 0: worker.snapshotImage() else: nil)))
  let reply = worker.mailbox.replies.recv()
  joinThread(worker.thread)
  worker.mailbox.commands.close()
  worker.mailbox.replies.close()
  deallocShared(worker.mailbox)
  worker.mailbox = nil
  let pendingError = worker.reply.error & worker.fatalError
  worker.reply = Reply()
  worker.reusable = nil
  worker.image = nil
  worker.audio = @[]
  if pendingError.len > 0:
    raise newException(IOError, pendingError & reply.error)
  reply.checked()

proc openCoreWorker*(corePath, romPath, saveDirectory: string, captureAudio = false,
    options: seq[CoreOption] = @[], statePath = "", raConfigPath = "",
    achievementsEnabled = false, captureDirectory = "", replayPath = "",
    screenstateDirectory = "", microphoneEnabled = false,
    microphoneFactory: MicrophoneFactory = nil, microphoneGainDb = 0): CoreWorker =
  ## Load a software core on its dedicated thread with one bounded frame in flight.
  ## Microphone factories execute on that thread and must not capture caller-owned state.
  result = CoreWorker(mailbox: cast[ptr Mailbox](allocShared0(sizeof(Mailbox))))
  result.mailbox.commands.open(1)
  result.mailbox.replies.open(1)
  createThread(result.thread, emulate, result.mailbox)
  var config = Command(kind: Configure, core: owned(corePath), rom: owned(romPath),
    saves: owned(saveDirectory), state: owned(statePath), captureAudio: captureAudio,
    raConfigPath: owned(raConfigPath), achievementsEnabled: achievementsEnabled,
    captureRoot: owned(captureDirectory), replayPath: owned(replayPath),
    screenstateDirectory: owned(screenstateDirectory), microphoneEnabled: microphoneEnabled,
    microphoneFactory: microphoneFactory, microphoneGainDb: microphoneGainDb)
  when defined(raTesting):
    config.raHttpTestHandler = workerRaHttpTestHandler
  for option in options: config.options.add((owned(option.key), owned(option.value)))
  result.mailbox.commands.send(move(config))
  var reply = result.mailbox.replies.recv()
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
  result.captureDirectory = reply.captureDirectory
  result.stateExport = reply.stateExport
  result.stateImport = reply.stateImport
  result.shutdown = reply.shutdown
  result.av = reply.av
  result.acceptAchievements(reply)

proc prefetch*(worker: CoreWorker, buttons: uint16, pointerInput = PointerInput()) =
  ## Start the next frame while the main thread presents the current one.
  if worker.pending or worker.ready or worker.shutdown: return
  worker.mailbox.commands.send(Command(kind: Step, buttons: buttons,
    pointerInput: pointerInput, reusable: move(worker.reusable)))
  worker.pending = true

proc step*(worker: CoreWorker, buttons: uint16, pointerInput = PointerInput(),
    compareVideo = false) =
  ## Consume one frame; optionally compare video before recycling its old storage.
  if worker.shutdown and not worker.ready: return
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

proc takeRaNotices*(worker: CoreWorker): seq[RaNotice] =
  ## Transfer achievement notifications accumulated from frames and paused updates.
  result = move(worker.raNotices)

proc idleAchievements*(worker: CoreWorker, withList = false) =
  ## Process achievement callbacks on the core thread without advancing emulation.
  discard worker.request(Command(kind: IdleAchievements, withList: withList))

proc save*(worker: CoreWorker) =
  ## Persist SRAM on the core thread without discarding a prefetched frame.
  discard worker.request(Command(kind: Save))

proc importStateData*(worker: CoreWorker, contents, source: string) =
  ## Serialize a state import; reject errors without losing the prior ready frame.
  let reply = worker.request(Command(kind: ImportState, contents: owned(contents),
    source: owned(source)), checkResult = false)
  if reply.stateImported:
    if reply.shutdown: worker.fatalError = reply.error
    worker.reply = Reply()
    worker.ready = false
    worker.audio = @[]
    worker.image = nil
    worker.reusable = nil
    worker.av = reply.av
    worker.shutdown = reply.shutdown
  reply.checked()

proc capture*(worker: CoreWorker, reason = "manual", withState = true) =
  ## Pair a frozen copy of the latest video with state from the same frame boundary.
  worker.finishPending()
  worker.reply.checked()
  let image = worker.snapshotImage()
  if image == nil: raise newException(IOError, "No completed frame to capture")
  discard worker.request(Command(kind: Capture, reusable: image,
    source: owned(reason), withState: withState))

proc exportState*(worker: CoreWorker): string =
  ## Export after all submitted frames without consuming their presentation results.
  var reply = worker.request(Command(kind: ExportState))
  result = move(reply.contents)

proc saveSlot*(worker: CoreWorker, slot: int) =
  ## Publish matching pixels and state only after the complete slot reaches disk.
  worker.finishPending()
  worker.reply.checked()
  let image = worker.snapshotImage()
  if image == nil: raise newException(IOError, "No completed frame to save")
  discard worker.request(Command(kind: SaveSlot, slot: slot, reusable: image))

proc pause*(worker: CoreWorker) =
  ## Quiesce emulation and discard queued PCM before a focus pause.
  worker.finishPending()
  worker.reply.checked()
  worker.reply.audio = @[]
  worker.audio = @[]
  discard worker.request(Command(kind: Pause))
