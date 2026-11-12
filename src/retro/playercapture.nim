import
  std/[json, os, sha1, strutils, tempfiles, times],
  pixie, zippy, zippy/crc,
  ./[libretro, playersave]

const
  PngSignature = "\x89PNG\r\n\x1a\n"
  PngSigLen = 8
  EbStType = "ebSt"
  EbSsMagic = "EBSS"
  MrStType = "mrSt"
  MrSsMagic = "MRSS"
  DbStMagic = "DBST"
  MrStVersion = 1'u16
  Sha1Size = 20
  CopierHeaderBytes = 512
  QueueBound = 8
  MaxReplayFrames = 10_000_000
  MaxStateBytes = 64 * 1024 * 1024
  MaxLogBytes = 64 * 1024 * 1024
  EnvelopeTrailerBytes = 4
  MinDbstBytes = 8
  ZeroChunk = 4096
  InputBufferBytes = 8192
  ReplayVersion = 1

type
  CaptureKind = enum
    PlainShot, EbStShot, MrStShot, FileWrite, LogAppend
  CaptureJob = object
    stop: bool
    path, sidecarPath, sidecar, state, romHash, coreHash, contents: string
    screenstatePath: string
    image: Image
    kind: CaptureKind
    romCrc: uint32
  CaptureMailbox = object
    jobs: Channel[CaptureJob]
    errors: Channel[string]
  CaptureWriter* = ref object
    directory*: string
    screenstateDirectory: string
    romHash, coreHash, coreName, coreVersion: string
    options: seq[tuple[key, value: string]]
    romCrc: uint32
    decompbound: bool
    segment, frame: int
    lastInput: ReplayInput
    haveLast, closed, replayDisabled: bool
    failure: string
    logBuffer: string
    logPath, manifestPath, checkpointPath: string
    reserved: seq[string]
    mailbox: ptr CaptureMailbox
    thread: Thread[ptr CaptureMailbox]
  ReplayInput* = object
    buttons*: uint16
    pointerInput*: PointerInput
  ReplayRecording* = object
    checkpoint*: string
    inputs*: seq[ReplayInput]
    options*: seq[tuple[key, value: string]]
    coreHash*, romHash*: string

proc owned(value: string): string =
  ## Copy a string before transferring ownership to another thread.
  result = newString(value.len)
  if value.len > 0: copyMem(addr result[0], unsafeAddr value[0], value.len)

proc addU16le(s: var string, value: uint16) =
  ## Append a little-endian 16-bit word.
  s.add char(value and 0xff)
  s.add char((value shr 8) and 0xff)

proc addU32le(s: var string, value: uint32) =
  ## Append a little-endian 32-bit word.
  s.add char(value and 0xff)
  s.add char((value shr 8) and 0xff)
  s.add char((value shr 16) and 0xff)
  s.add char((value shr 24) and 0xff)

proc addU32be(s: var string, value: uint32) =
  ## Append a big-endian 32-bit word.
  s.add char((value shr 24) and 0xff)
  s.add char((value shr 16) and 0xff)
  s.add char((value shr 8) and 0xff)
  s.add char(value and 0xff)

proc readU16le(data: string, offset: int): uint16 =
  ## Read a little-endian 16-bit word.
  data[offset].uint8.uint16 or (data[offset + 1].uint8.uint16 shl 8)

proc readU32le(data: string, offset: int): uint32 =
  ## Read a little-endian 32-bit word.
  data[offset].uint8.uint32 or (data[offset + 1].uint8.uint32 shl 8) or
    (data[offset + 2].uint8.uint32 shl 16) or (data[offset + 3].uint8.uint32 shl 24)

proc readU32be(data: string, offset: int): uint32 =
  ## Read a big-endian 32-bit word.
  (data[offset].uint8.uint32 shl 24) or (data[offset + 1].uint8.uint32 shl 16) or
    (data[offset + 2].uint8.uint32 shl 8) or data[offset + 3].uint8.uint32

proc isZeroRange(data: string, start, finish: int): bool =
  ## True when every byte in the half-open range is zero.
  var zeros: array[ZeroChunk, byte]
  var offset = start
  while offset < finish:
    let n = min(ZeroChunk, finish - offset)
    if not equalMem(unsafeAddr data[offset], addr zeros[0], n):
      return false
    offset += n
  true

proc canonicalizeState(state: string): string =
  ## Strip a verified 64 MiB DBST export envelope to canonical raw DBST.
  if state.len != MaxStateBytes or not state.startsWith(DbStMagic):
    return state
  let
    payload = readU32le(state, state.len - EnvelopeTrailerBytes).int
    paddingEnd = state.len - EnvelopeTrailerBytes
  if payload < MinDbstBytes or payload > paddingEnd:
    raise newException(ValueError, "Invalid DBST export envelope length")
  if not isZeroRange(state, payload, paddingEnd):
    raise newException(ValueError, "DBST export envelope padding is not zero")
  state[0 ..< payload]

proc normalizedRomCrc32*(rom: string): uint32 =
  ## CRC32 of ROM bytes after dropping an optional 512-byte copier header.
  var start = 0
  if rom.len mod 1024 == CopierHeaderBytes:
    start = CopierHeaderBytes
  let body = rom.len - start
  if body == 0: return 0
  crc32(unsafeAddr rom[start], body)

proc sha1Hex(path: string): string =
  ## SHA1 of a file as uppercase hex, matching `$secureHashFile`.
  $secureHashFile(path)

proc digestBytes(hex: string): string =
  ## Decode a 40-character SHA1 hex string into 20 raw bytes.
  let normalized = hex.strip()
  if normalized.len != Sha1Size * 2:
    raise newException(ValueError, "Expected a 40-character SHA1 hash")
  result = newString(Sha1Size)
  let digest = Sha1Digest(parseSecureHash(normalized))
  copyMem(addr result[0], unsafeAddr digest[0], Sha1Size)

proc hexOf(data: string, start = 0, length = Sha1Size): string =
  ## Format raw digest bytes as uppercase hex.
  for offset in start ..< start + length:
    result.add toHex(int(data[offset].uint8), 2)

proc pngChunk(typ, data: string): string =
  ## Build a PNG chunk with a zippy CRC over type and payload.
  var body = typ & data
  let crc = crc32(addr body[0], body.len)
  result.addU32be(data.len.uint32)
  result.add(body)
  result.addU32be(crc)

proc findChunk(png, typ: string): tuple[start, length: int] =
  ## Locate a named chunk's payload, or (-1, 0) when missing.
  result = (-1, 0)
  if png.len < PngSigLen + 12 or not png.startsWith(PngSignature):
    return
  var pos = PngSigLen
  while pos + 12 <= png.len:
    let length = readU32be(png, pos).int
    if length < 0 or pos + 12 + length > png.len:
      return
    if png[pos + 4 ..< pos + 8] == typ:
      return (pos + 8, length)
    pos += 12 + length

proc findIend(png: string): int =
  ## Byte offset of the IEND length field, or -1.
  if png.len < PngSigLen + 12 or not png.startsWith(PngSignature):
    return -1
  var pos = PngSigLen
  while pos + 12 <= png.len:
    let length = readU32be(png, pos).int
    if length < 0 or pos + 12 + length > png.len:
      return -1
    if png[pos + 4 ..< pos + 8] == "IEND":
      return pos
    pos += 12 + length
  -1

proc insertChunk(png, typ, data: string): string =
  ## Insert an ancillary chunk immediately before IEND.
  let chunk = pngChunk(typ, data)
  let iend = findIend(png)
  if iend >= 0:
    png[0 ..< iend] & chunk & png[iend .. ^1]
  else:
    png & chunk

proc deflateState(state: string): string =
  ## Raw-deflate state bytes; empty input stays empty.
  if state.len == 0: return
  compress(state, DefaultCompression, dfDeflate)

proc inflateState(payload: string, rawLen: int): string =
  ## Inflate a raw-deflate payload and require the recorded length.
  if rawLen < 0:
    raise newException(ValueError, "Negative screenstate length")
  if payload.len == 0:
    if rawLen != 0:
      raise newException(ValueError, "Empty screenstate payload")
    return
  result = uncompress(payload, dfDeflate)
  if result.len != rawLen:
    raise newException(ValueError, "Screenstate length does not match")

proc ebStPayload(state: string, romCrc: uint32): string =
  ## EBSS envelope used by decompbound ebSt chunks.
  if state.len < MinDbstBytes or not state.startsWith(DbStMagic):
    raise newException(ValueError, "Decompbound capture does not contain DBST state")
  let version = readU32le(state, 4)
  if version == 0 or version > high(uint16).uint32:
    raise newException(ValueError, "DBST version does not fit the ebSt header")
  result = EbSsMagic
  result.addU16le(version.uint16)
  result.addU32le(romCrc)
  result.addU32le(state.len.uint32)
  result.add(deflateState(state))

proc mrStPayload(state, romHash, coreHash: string): string =
  ## Frontend-owned mrSt envelope with SHA1 identities and opaque bytes.
  result = MrSsMagic
  result.addU16le(MrStVersion)
  result.add(digestBytes(romHash))
  result.add(digestBytes(coreHash))
  result.addU32le(state.len.uint32)
  result.add(deflateState(state))

proc embedPng(png: string, job: CaptureJob): string =
  ## Attach ebSt or mrSt when the job carries state.
  case job.kind
  of PlainShot: png
  of EbStShot: insertChunk(png, EbStType, ebStPayload(job.state, job.romCrc))
  of MrStShot: insertChunk(png, MrStType, mrStPayload(job.state, job.romHash, job.coreHash))
  of FileWrite, LogAppend:
    raise newException(ValueError, "A recording write is not an image capture")

proc encodeScreenstatePng*(image: Image, state, romHash, coreHash: string,
    romCrc: uint32, decompbound: bool): string =
  ## Encode an image with one validated ebSt or mrSt screenstate PNG chunk.
  if image == nil:
    raise newException(ValueError, "Capture image is missing")
  if state.len == 0 or state.len > MaxStateBytes:
    raise newException(ValueError, "Screenstate must contain between one byte and 64 MiB")
  let canonical = if decompbound: canonicalizeState(state) else: state
  let payload = if decompbound: ebStPayload(canonical, romCrc)
    else: mrStPayload(canonical, romHash, coreHash)
  insertChunk(image.encodeImage(PngFormat), if decompbound: EbStType else: MrStType, payload)

proc writeShot(job: CaptureJob) =
  ## Encode a cloned image and write the PNG plus sidecar in the session root.
  if job.image == nil:
    raise newException(ValueError, "Capture image is missing")
  let png = embedPng(job.image.encodeImage(PngFormat), job)
  writeSave(job.path, png)
  writeSave(job.sidecarPath, job.sidecar)
  if job.screenstatePath.len > 0:
    createDir(job.screenstatePath.parentDir)
    discard writeNewSave(job.screenstatePath, png)

proc writeCaptures(mailbox: ptr CaptureMailbox) {.thread.} =
  ## Compress and write queued screenshots without blocking the caller.
  {.cast(gcsafe).}:
    var failed = false
    while true:
      var job = mailbox.jobs.recv()
      if job.stop: break
      if failed: continue
      try:
        case job.kind
        of FileWrite: writeSave(job.path, job.contents)
        of LogAppend:
          let file = open(job.path, fmAppend)
          try:
            file.write(job.contents)
            file.flushSaveFile()
          finally: file.close()
        else: writeShot(job)
      except CatchableError as error:
        failed = true
        mailbox.errors.send(error.msg & "\n" & error.getStackTrace())

proc pendingError(writer: CaptureWriter): string =
  ## Retain and return any background writer failure without blocking.
  if writer == nil: return
  if writer.mailbox != nil:
    while true:
      let next = writer.mailbox.errors.tryRecv()
      if not next.dataAvailable: break
      if writer.failure.len > 0: writer.failure.add("\n")
      writer.failure.add(next.msg)
  writer.failure

proc raisePending(writer: CaptureWriter) =
  ## Surface a background write failure on the next mutating call.
  let message = pendingError(writer)
  if message.len > 0:
    raise newException(IOError, message)

proc optionsJson(options: seq[tuple[key, value: string]]): JsonNode =
  ## Encode options as objects so replay round-trips the tuple fields.
  result = newJArray()
  for option in options:
    result.add(%*{"key": option.key, "value": option.value})

proc parseOptions(node: JsonNode): seq[tuple[key, value: string]] =
  ## Load options objects back into the public tuple sequence.
  if node == nil or node.kind != JArray:
    raise newException(ValueError, "Replay options must be an array")
  for item in node:
    if item.kind != JObject or not item.hasKey("key") or not item.hasKey("value") or
        item["key"].kind != JString or item["value"].kind != JString:
      raise newException(ValueError, "Replay option is missing key/value")
    result.add((item["key"].getStr, item["value"].getStr))

proc segmentName(index: int): string =
  ## Zero-padded segment file stem such as segment_0001.
  "segment_" & intToStr(index, 4)

proc uniquePng(writer: CaptureWriter, stem: string): string =
  ## Choose an unused PNG name in the session root, including queued names.
  result = writer.directory / stem & ".png"
  var n = 2
  while result in writer.reserved or fileExists(result) or
      fileExists(result.changeFileExt("json")):
    result = writer.directory / stem & "_" & $n & ".png"
    inc n
  writer.reserved.add(result)

proc shotStem(writer: CaptureWriter, reason: string): string =
  ## EarthBound timestamp names for decompbound; generic names keep the reason.
  let stamp = now().format("yyyyMMdd-HHmmss")
  if writer.decompbound:
    "earthbound_" & stamp
  else:
    let label = if reason.len > 0: reason else: "manual"
    "capture_" & stamp & "_" & label

proc sidecarJson(writer: CaptureWriter, reason, filename: string, embedded: bool): string =
  ## Map a snapshot to its segment and zero-based last recorded frame.
  let frame = if writer.frame > 0: writer.frame - 1 else: 0
  $(%*{
    "segment": writer.segment,
    "frame": frame,
    "frames": writer.frame,
    "replay": (if writer.segment > 0: segmentName(writer.segment) & ".json" else: ""),
    "reason": reason,
    "embedded": embedded,
    "file": filename
  })

proc writeMetadata(writer: CaptureWriter, romPath, corePath: string) =
  ## Persist ROM/core identity hashes and options beside the session files.
  let document = %*{
    "romPath": romPath,
    "corePath": corePath,
    "coreName": writer.coreName,
    "coreVersion": writer.coreVersion,
    "romHash": writer.romHash,
    "coreHash": writer.coreHash,
    "options": optionsJson(writer.options)
  }
  writeSave(writer.directory / "metadata.json", document.pretty)

proc flushSegment(writer: CaptureWriter) =
  ## Queue a complete replay boundary before its screenshot can reach disk.
  if writer.segment <= 0 or writer.logPath.len == 0:
    return
  writer.logBuffer.add($(%*{"length": writer.frame}) & "\n")
  writer.mailbox.jobs.send(CaptureJob(kind: LogAppend, path: owned(writer.logPath),
    contents: move(writer.logBuffer)))
  let document = %*{
    "version": ReplayVersion,
    "checkpoint": writer.checkpointPath.extractFilename,
    "inputs": writer.logPath.extractFilename,
    "frames": writer.frame,
    "options": optionsJson(writer.options),
    "coreHash": writer.coreHash,
    "romHash": writer.romHash
  }
  writer.mailbox.jobs.send(CaptureJob(kind: FileWrite, path: owned(writer.manifestPath),
    contents: $document))

proc finalizeSegment(writer: CaptureWriter) =
  ## Queue the completed segment and release its caller-side recording buffers.
  writer.flushSegment()
  writer.logPath = ""
  writer.manifestPath = ""
  writer.checkpointPath = ""
  writer.haveLast = false

proc startWriter(writer: CaptureWriter) =
  ## Own PNG compression and file writes on a bounded background queue.
  writer.mailbox = cast[ptr CaptureMailbox](allocShared0(sizeof(CaptureMailbox)))
  writer.mailbox.jobs.open(QueueBound)
  writer.mailbox.errors.open()
  try:
    createThread(writer.thread, writeCaptures, writer.mailbox)
  except CatchableError:
    writer.mailbox.jobs.close()
    writer.mailbox.errors.close()
    deallocShared(writer.mailbox)
    writer.mailbox = nil
    raise

proc openCaptureWriter*(root, romPath, corePath, coreName, coreVersion: string;
    options: seq[tuple[key, value: string]] = @[], screenstateDirectory = ""): CaptureWriter =
  ## Create a unique session directory with ROM/core identity metadata.
  if not fileExists(romPath):
    raise newException(IOError, "Missing ROM: " & romPath)
  if not fileExists(corePath):
    raise newException(IOError, "Missing core: " & corePath)
  let captureRoot = absolutePath(root)
  createDir(captureRoot)
  result = CaptureWriter(
    directory: createTempDir("session-", "", captureRoot),
    screenstateDirectory: screenstateDirectory,
    coreName: coreName,
    coreVersion: coreVersion,
    decompbound: coreName.toLowerAscii == "decompbound"
  )
  for option in options:
    result.options.add((owned(option.key), owned(option.value)))
  let rom = readFile(romPath)
  result.romHash = $secureHash(rom)
  result.coreHash = sha1Hex(corePath)
  result.romCrc = normalizedRomCrc32(rom)
  result.writeMetadata(absolutePath(romPath), absolutePath(corePath))
  result.startWriter()

proc replayEnabled*(writer: CaptureWriter): bool =
  ## Report whether this session can record all input needed for replay.
  writer != nil and not writer.replayDisabled

proc beginSegment*(writer: CaptureWriter, state: string) =
  ## Start a new segment with a canonical checkpoint and a zero-based frame count.
  if writer == nil or writer.closed or writer.mailbox == nil:
    raise newException(ValueError, "Capture writer is closed")
  writer.raisePending()
  if writer.replayDisabled: return
  let checkpoint = if writer.decompbound: canonicalizeState(state) else: state
  if checkpoint.len == 0 or checkpoint.len > MaxStateBytes:
    raise newException(ValueError, "Checkpoint must contain at most 64 MiB of state")
  writer.finalizeSegment()
  inc writer.segment
  writer.frame = 0
  writer.haveLast = false
  let stem = segmentName(writer.segment)
  writer.checkpointPath = writer.directory / stem & ".state"
  writer.logPath = writer.directory / stem & ".jsonl"
  writer.manifestPath = writer.directory / stem & ".json"
  writer.mailbox.jobs.send(CaptureJob(kind: FileWrite, path: owned(writer.checkpointPath),
    contents: owned(checkpoint)))
  writer.mailbox.jobs.send(CaptureJob(kind: FileWrite, path: owned(writer.logPath)))
  writer.flushSegment()

proc recordInput*(writer: CaptureWriter, buttons: uint16, pointerInput: PointerInput) =
  ## Record the input applied to the next executed core frame; repeats stay sparse.
  if writer != nil and writer.replayDisabled: return
  if writer == nil or writer.closed or writer.segment <= 0 or writer.logPath.len == 0:
    raise newException(ValueError, "Capture segment has not started")
  writer.raisePending()
  let input = ReplayInput(buttons: buttons, pointerInput: pointerInput)
  if not writer.haveLast or writer.lastInput != input:
    writer.logBuffer.add($(%*{
      "frame": writer.frame,
      "buttons": buttons.int,
      "x": pointerInput.x.int,
      "y": pointerInput.y.int,
      "pressed": pointerInput.pressed
    }) & "\n")
    writer.lastInput = input
    writer.haveLast = true
  inc writer.frame
  if writer.logBuffer.len >= InputBufferBytes: writer.flushSegment()

proc disableReplay*(writer: CaptureWriter) =
  ## Keep images and states while invalidating a segment with unrecorded live input.
  if writer == nil or writer.replayDisabled: return
  writer.raisePending()
  writer.replayDisabled = true
  if writer.manifestPath.len > 0:
    writer.mailbox.jobs.send(CaptureJob(kind: FileWrite, path: owned(writer.manifestPath),
      contents: $(%*{"version": ReplayVersion,
        "unavailable": "Live microphone input was not recorded"})))
  writer.logBuffer.setLen(0)
  writer.logPath = ""
  writer.manifestPath = ""
  writer.checkpointPath = ""
  writer.segment = 0
  writer.frame = 0
  writer.haveLast = false

proc capture*(writer: CaptureWriter, image: Image, state = "", reason = "manual") =
  ## Clone owned pixels and queue a plain or self-contained state PNG in the session root.
  if writer == nil or writer.closed or writer.mailbox == nil:
    raise newException(ValueError, "Capture writer is closed")
  if image == nil:
    raise newException(ValueError, "Capture image is missing")
  writer.raisePending()
  writer.flushSegment()
  var job = CaptureJob(
    path: "",
    sidecarPath: "",
    sidecar: "",
    state: owned(if writer.decompbound: canonicalizeState(state) else: state),
    romHash: owned(writer.romHash),
    coreHash: owned(writer.coreHash),
    image: image.copy(),
    kind: PlainShot,
    romCrc: writer.romCrc
  )
  if job.state.len > 0:
    job.kind = if writer.decompbound: EbStShot else: MrStShot
  let path = uniquePng(writer, writer.shotStem(reason))
  job.path = owned(path)
  job.sidecarPath = owned(path.changeFileExt("json"))
  job.sidecar = owned(writer.sidecarJson(reason, path.extractFilename, job.state.len > 0))
  if writer.screenstateDirectory.len > 0 and job.state.len > 0 and reason in ["manual", "exit"]:
    job.screenstatePath = owned(writer.screenstateDirectory / path.extractFilename)
  writer.mailbox.jobs.send(move(job))

proc close*(writer: CaptureWriter) =
  ## Finish the open segment, drain queued screenshots, and raise collected I/O errors.
  if writer == nil or writer.closed: return
  writer.closed = true
  var message: string
  try:
    writer.finalizeSegment()
  except CatchableError as error:
    message = error.msg
  if writer.mailbox != nil:
    writer.mailbox.jobs.send(CaptureJob(stop: true))
    joinThread(writer.thread)
    let pending = pendingError(writer)
    if pending.len > 0:
      if message.len > 0: message.add("\n")
      message.add(pending)
    writer.mailbox.jobs.close()
    writer.mailbox.errors.close()
    deallocShared(writer.mailbox)
    writer.mailbox = nil
  if message.len > 0:
    raise newException(IOError, message)

proc relativeName(value, kind: string): string =
  ## Reject absolute or traversing filenames stored in a segment manifest.
  if value.len == 0 or value.isAbsolute or value == "." or value == ".." or
      '/' in value or '\\' in value or DirSep in value:
    raise newException(ValueError, "Replay " & kind & " path is not a local file name")
  value

proc parseChange(node: JsonNode): ReplayInput =
  ## Load one sparse input delta.
  for key in ["buttons", "x", "y"]:
    if not node.hasKey(key) or node[key].kind != JInt:
      raise newException(ValueError, "Replay input requires integer " & key)
  if not node.hasKey("pressed") or node["pressed"].kind != JBool:
    raise newException(ValueError, "Replay input requires a pressed boolean")
  if node.hasKey("buttons"):
    let buttons = node["buttons"].getInt
    if buttons < 0 or buttons > int(high(uint16)):
      raise newException(ValueError, "Replay buttons are out of range")
    result.buttons = buttons.uint16
  if node.hasKey("x"):
    let x = node["x"].getInt
    if x < int(low(int16)) or x > int(high(int16)):
      raise newException(ValueError, "Replay pointer x is out of range")
    result.pointerInput.x = x.int16
  if node.hasKey("y"):
    let y = node["y"].getInt
    if y < int(low(int16)) or y > int(high(int16)):
      raise newException(ValueError, "Replay pointer y is out of range")
    result.pointerInput.y = y.int16
  if node.hasKey("pressed"):
    result.pointerInput.pressed = node["pressed"].getBool

proc readReplay*(path: string): ReplayRecording =
  ## Load one segment manifest, sparse log and canonical checkpoint for frontend replay.
  if not fileExists(path):
    raise newException(IOError, "Missing replay segment: " & path)
  if getFileSize(path) <= 0 or getFileSize(path) > MaxLogBytes:
    raise newException(ValueError, "Replay manifest size is out of bounds")
  let
    document = parseJson(readFile(path))
    directory = path.parentDir
  if document.kind != JObject:
    raise newException(ValueError, "Replay manifest is not an object")
  if not document.hasKey("version") or document["version"].getInt != ReplayVersion:
    raise newException(ValueError, "Unsupported replay manifest version")
  if document.hasKey("unavailable"):
    raise newException(IOError, "Replay unavailable: " & document["unavailable"].getStr)
  if document["frames"].kind != JInt:
    raise newException(ValueError, "Replay frame count must be an integer")
  let
    checkpointName = relativeName(document["checkpoint"].getStr, "checkpoint")
    inputName = relativeName(document["inputs"].getStr, "input log")
    checkpointPath = directory / checkpointName
    inputPath = directory / inputName
    frames = document["frames"].getInt
  if frames < 0 or frames > MaxReplayFrames:
    raise newException(ValueError, "Replay frame count is out of bounds")
  if not fileExists(checkpointPath):
    raise newException(IOError, "Missing replay checkpoint: " & checkpointPath)
  if not fileExists(inputPath):
    raise newException(IOError, "Missing replay input log: " & inputPath)
  if getFileSize(checkpointPath) <= 0 or getFileSize(checkpointPath) > MaxStateBytes:
    raise newException(ValueError, "Replay checkpoint must contain at most 64 MiB of state")
  if getFileSize(inputPath) > MaxLogBytes:
    raise newException(ValueError, "Replay input log exceeds the 64 MiB limit")
  result.checkpoint = readFile(checkpointPath)
  result.options = parseOptions(document["options"])
  result.coreHash = document["coreHash"].getStr
  result.romHash = document["romHash"].getStr
  result.inputs = newSeq[ReplayInput](frames)
  var
    current = ReplayInput()
    cursor = 0
    length = -1
    lastFrame = -1
  for raw in readFile(inputPath).splitLines():
    if raw.len == 0: continue
    let node = parseJson(raw)
    if node.kind != JObject:
      raise newException(ValueError, "Replay log line is not an object")
    if node.hasKey("length") and not node.hasKey("frame"):
      if node["length"].kind != JInt:
        raise newException(ValueError, "Replay log boundary must be an integer")
      let boundary = node["length"].getInt
      if boundary < length or boundary < 0 or boundary > frames or boundary <= lastFrame:
        raise newException(ValueError, "Replay log boundary is out of bounds")
      length = boundary
      if length == frames: break
      continue
    if not node.hasKey("frame"):
      raise newException(ValueError, "Replay log line is missing a frame")
    if node["frame"].kind != JInt:
      raise newException(ValueError, "Replay input frame must be an integer")
    let frame = node["frame"].getInt
    if frame < 0 or frame >= frames or frame <= lastFrame or frame < length or
        (lastFrame < 0 and frame != 0):
      raise newException(ValueError, "Replay log frame is out of bounds")
    while cursor < frame:
      result.inputs[cursor] = current
      inc cursor
    current = parseChange(node)
    result.inputs[frame] = current
    cursor = frame + 1
    lastFrame = frame
  while cursor < frames:
    result.inputs[cursor] = current
    inc cursor
  if length != frames or (frames > 0 and lastFrame < 0):
    raise newException(ValueError, "Replay log length does not match the manifest")

proc chunkCrc(png: string, dataStart, dataLen: int): bool =
  ## True when the PNG chunk CRC matches type plus payload.
  let typeStart = dataStart - 4
  let crcOff = dataStart + dataLen
  if typeStart < 0 or crcOff + 4 > png.len:
    return false
  crc32(unsafeAddr png[typeStart], dataLen + 4) == readU32be(png, crcOff)

proc unwrapMrSt(png, expectedRomHash, expectedCoreHash: string): string =
  ## Validate a frontend mrSt wrapper and return the opaque serialized bytes.
  let (start, length) = findChunk(png, MrStType)
  if start < 0:
    raise newException(ValueError, "PNG has no embedded mrSt screenstate")
  if not chunkCrc(png, start, length):
    raise newException(ValueError, "Screenstate mrSt checksum mismatch")
  const headerLen = 4 + 2 + Sha1Size + Sha1Size + 4
  if length < headerLen:
    raise newException(ValueError, "Truncated mrSt screenstate header")
  let data = png[start ..< start + length]
  if not data.startsWith(MrSsMagic):
    raise newException(ValueError, "Malformed mrSt screenstate")
  if readU16le(data, 4) != MrStVersion:
    raise newException(ValueError, "Unsupported mrSt screenstate version")
  let
    romHash = hexOf(data, 6)
    coreHash = hexOf(data, 6 + Sha1Size)
    rawLen = readU32le(data, 6 + Sha1Size * 2).int
  if romHash.toLowerAscii != expectedRomHash.strip().toLowerAscii:
    raise newException(ValueError, "Screenstate ROM hash does not match")
  if coreHash.toLowerAscii != expectedCoreHash.strip().toLowerAscii:
    raise newException(ValueError, "Screenstate core hash does not match")
  if rawLen > MaxStateBytes:
    raise newException(ValueError, "Screenstate exceeds the 64 MiB import limit")
  inflateState(data[headerLen .. ^1], rawLen)

proc unwrapScreenstate*(contents, expectedRomHash, expectedCoreHash: string): string =
  ## Unwrap a frontend mrSt PNG; leave raw DBST and ebSt PNGs unchanged for core import.
  if contents.len >= PngSigLen and contents.startsWith(PngSignature):
    if findChunk(contents, MrStType).start >= 0:
      return unwrapMrSt(contents, expectedRomHash, expectedCoreHash)
    if findIend(contents) < 0:
      raise newException(ValueError, "Truncated PNG screenstate")
    return contents
  contents
