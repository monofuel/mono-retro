import
  std/[json, monotimes, os, sha1, strutils, tempfiles, times],
  pixie,
  retro/[libretro, playercapture, playersave]

const
  MaxStateBytes = 64 * 1024 * 1024
  DbStPrefix = "DBST" & "\x02\x00\x00\x00"

proc imageOf(color: ColorRGBX): Image =
  ## Tiny owned frame used by capture tests.
  result = newImage(2, 2)
  result.fill(color)

proc writeU32le(s: var string, offset: int, value: uint32) =
  ## Store a little-endian trailer used by the 64 MiB export envelope.
  s[offset] = char(value and 0xff)
  s[offset + 1] = char((value shr 8) and 0xff)
  s[offset + 2] = char((value shr 16) and 0xff)
  s[offset + 3] = char((value shr 24) and 0xff)

proc paddedEnvelope(payload = DbStPrefix): string =
  ## Build a verified Decompbound libretro export envelope.
  result = newString(MaxStateBytes)
  copyMem(addr result[0], unsafeAddr payload[0], payload.len)
  writeU32le(result, result.len - 4, payload.len.uint32)

proc jsonlChanges(path: string): seq[JsonNode] =
  ## Sparse change lines from a segment log, excluding the length trailer.
  for line in readFile(path).splitLines():
    if line.len == 0: continue
    let node = parseJson(line)
    if node.hasKey("frame"):
      result.add(node)

proc pngs(directory: string): seq[string] =
  ## Session-root PNG paths.
  for path in walkFiles(directory / "*.png"):
    result.add(path)

proc segments(directory: string): seq[string] =
  ## Session-root segment manifests in numeric order.
  for path in walkFiles(directory / "segment_*.json"):
    result.add(path)

proc chunkPayload(png, typ: string): string =
  ## Return the named PNG chunk payload for format checks.
  if not png.startsWith("\x89PNG\r\n\x1a\n"):
    raise newException(ValueError, "Not a PNG")
  var pos = 8
  while pos + 12 <= png.len:
    let
      length = (png[pos].uint8.uint32 shl 24) or (png[pos + 1].uint8.uint32 shl 16) or
        (png[pos + 2].uint8.uint32 shl 8) or png[pos + 3].uint8.uint32
      n = length.int
    if pos + 12 + n > png.len:
      break
    if png[pos + 4 ..< pos + 8] == typ:
      return png[pos + 8 ..< pos + 8 + n]
    pos += 12 + n
  raise newException(ValueError, "Missing " & typ & " chunk")

proc readU32le(data: string, offset: int): uint32 =
  ## Little-endian word used to inspect ebSt headers.
  data[offset].uint8.uint32 or (data[offset + 1].uint8.uint32 shl 8) or
    (data[offset + 2].uint8.uint32 shl 16) or (data[offset + 3].uint8.uint32 shl 24)

template expectError(body: untyped) =
  ## Require a CatchableError from malformed capture or replay data.
  var raised = false
  try: body
  except CatchableError: raised = true
  doAssert raised

proc main() =
  ## Cover sparse replay logs, PNG envelopes, padding strip, errors and drain.
  let
    directory = createTempDir("player-capture-", "")
    rom = directory / "game.smc"
    core = directory / "core.so"
    body = repeat('R', 1024)
  defer: removeDir(directory)
  writeFile(rom, body)
  writeFile(core, "COREBYTES")
  block delayedWriteFailure:
    let file = open("/dev/full", fmWrite)
    try:
      file.write("buffered bytes")
      expectError: file.flushSaveFile()
    finally: file.close()
  let
    romHash = $secureHashFile(rom)
    coreHash = $secureHashFile(core)
    red = rgbx(255, 0, 0, 255)
    green = rgbx(0, 255, 0, 255)

  block existingScreenstates:
    let path = directory / "existing.png"
    writeFile(path, "previous screenstate")
    doAssert writeNewSave(path, "first new capture") == directory / "existing_2.png"
    doAssert writeNewSave(path, "second new capture") == directory / "existing_3.png"
    doAssert readFile(path) == "previous screenstate"
    doAssert readFile(directory / "existing_2.png") == "first new capture"
    doAssert readFile(directory / "existing_3.png") == "second new capture"

  block screenstateArchive:
    for name in ["Decompbound", "mGBA"]:
      let
        archive = directory / name / "Pictures" / "Screenshots"
        writer = openCaptureWriter(directory / name / "sessions", rom, core, name, "1",
          screenstateDirectory = archive)
        state = if name == "Decompbound": DbStPrefix else: "opaque-state"
      writer.beginSegment(state)
      writer.recordInput(0, PointerInput())
      writer.capture(imageOf(red), reason = "auto")
      writer.capture(imageOf(red), state, "manual")
      writer.capture(imageOf(green), state, "exit")
      writer.capture(imageOf(red), reason = "manual")
      writer.close()
      doAssert pngs(writer.directory).len == 4
      let archived = pngs(archive)
      doAssert archived.len == 2, "Only manual and exit screenstates belong in the archive"
      for path in archived:
        let contents = readFile(path)
        doAssert contents == readFile(writer.directory / path.extractFilename)
        if name == "Decompbound":
          doAssert chunkPayload(contents, "ebSt").startsWith("EBSS")
        else:
          doAssert unwrapScreenstate(contents, romHash, coreHash) == state
      doAssert readReplay(writer.directory / "segment_0001.json").inputs.len == 1

  block sparseReplay:
    let writer = openCaptureWriter(directory / "sparse", rom, core, "mGBA", "1")
    doAssert dirExists(writer.directory)
    doAssert fileExists(writer.directory / "metadata.json")
    writer.beginSegment("ckpt-a")
    writer.recordInput(1, PointerInput())
    writer.recordInput(1, PointerInput())
    writer.recordInput(1, PointerInput())
    writer.recordInput(1, PointerInput(x: 9, y: -8, pressed: true))
    writer.recordInput(1, PointerInput(x: 9, y: -8, pressed: true))
    writer.recordInput(2, PointerInput())
    writer.recordInput(2, PointerInput())
    writer.recordInput(2, PointerInput())
    writer.recordInput(2, PointerInput())
    writer.recordInput(2, PointerInput(x: 1, y: 2, pressed: false))
    writer.close()
    let
      manifests = segments(writer.directory)
      recording = readReplay(manifests[0])
      changes = jsonlChanges(writer.directory / "segment_0001.jsonl")
    doAssert manifests == @[writer.directory / "segment_0001.json"]
    doAssert recording.checkpoint == "ckpt-a"
    doAssert recording.romHash == romHash and recording.coreHash == coreHash
    doAssert recording.options.len == 0
    doAssert recording.inputs.len == 10
    doAssert recording.inputs[0].buttons == 1
    doAssert recording.inputs[2].buttons == 1 and recording.inputs[2].pointerInput == PointerInput()
    doAssert recording.inputs[3].pointerInput == PointerInput(x: 9, y: -8, pressed: true)
    doAssert recording.inputs[8].buttons == 2 and recording.inputs[8].pointerInput == PointerInput()
    doAssert recording.inputs[9] == ReplayInput(buttons: 2, pointerInput: PointerInput(x: 1, y: 2))
    doAssert changes.len == 4
    doAssert changes[0]["frame"].getInt == 0
    doAssert changes[^1]["frame"].getInt == 9
    var lengthLine = ""
    for line in readFile(writer.directory / "segment_0001.jsonl").splitLines():
      if line.len > 0: lengthLine = line
    doAssert parseJson(lengthLine)["length"].getInt == 10

  block multiSegment:
    let writer = openCaptureWriter(directory / "multi", rom, core, "mGBA", "1",
      @[("key", "on")])
    writer.beginSegment("one")
    writer.recordInput(256, PointerInput(x: 12, y: -34, pressed: true))
    writer.recordInput(256, PointerInput(x: 12, y: -34, pressed: true))
    writer.recordInput(0, PointerInput())
    writer.beginSegment("two")
    writer.recordInput(4, PointerInput(pressed: true))
    writer.recordInput(4, PointerInput(pressed: true))
    writer.close()
    let
      first = readReplay(writer.directory / "segment_0001.json")
      second = readReplay(writer.directory / "segment_0002.json")
    doAssert first.checkpoint == "one" and second.checkpoint == "two"
    doAssert first.inputs.len == 3 and second.inputs.len == 2
    doAssert first.inputs[0].buttons == 256
    doAssert first.inputs[0].pointerInput == PointerInput(x: 12, y: -34, pressed: true)
    doAssert first.inputs[2].buttons == 0
    doAssert second.inputs[0].buttons == 4 and second.inputs[1].buttons == 4
    doAssert first.options == @[("key", "on")] and second.options == first.options

  block plainVersusEmbedded:
    let
      generic = openCaptureWriter(directory / "generic", rom, core, "mGBA", "1")
      bound = openCaptureWriter(directory / "eb", rom, core, "Decompbound", "2")
      source = imageOf(red)
    generic.beginSegment("g")
    generic.recordInput(0, PointerInput())
    generic.capture(source, reason = "auto")
    generic.capture(source, "opaque-state", "manual")
    source.fill(green)
    generic.close()
    bound.beginSegment(paddedEnvelope())
    bound.recordInput(0, PointerInput())
    bound.capture(imageOf(red), paddedEnvelope(), "manual")
    bound.capture(imageOf(red), reason = "auto")
    bound.close()
    let
      genericPngs = pngs(generic.directory)
      boundPngs = pngs(bound.directory)
    doAssert genericPngs.len == 2 and boundPngs.len == 2
    var
      plainGeneric, mrSt, ebSt, plainBound = 0
    for path in genericPngs:
      let contents = readFile(path)
      doAssert readImage(path).data[0] == red
      doAssert fileExists(path.changeFileExt("json"))
      if contents.contains("mrSt"):
        inc mrSt
        doAssert unwrapScreenstate(contents, romHash, coreHash) == "opaque-state"
        doAssert not contents.contains("ebSt")
      else:
        inc plainGeneric
        doAssert unwrapScreenstate(contents, romHash, coreHash) == contents
        doAssert not contents.contains("mrSt")
    doAssert plainGeneric == 1 and mrSt == 1
    for path in boundPngs:
      let contents = readFile(path)
      doAssert path.extractFilename.startsWith("earthbound_")
      doAssert parseJson(readFile(path.changeFileExt("json")))["segment"].getInt == 1
      if contents.contains("ebSt"):
        inc ebSt
        doAssert unwrapScreenstate(contents, romHash, coreHash) == contents
        doAssert not contents.contains("mrSt")
        let payload = chunkPayload(contents, "ebSt")
        doAssert payload.startsWith("EBSS")
        doAssert payload[4].uint8 == 2 and payload[5].uint8 == 0
        doAssert readU32le(payload, 10) == DbStPrefix.len.uint32
      else:
        inc plainBound
        doAssert not contents.contains("ebSt")
    doAssert ebSt == 1 and plainBound == 1
    let replay = readReplay(bound.directory / "segment_0001.json")
    doAssert replay.checkpoint == DbStPrefix
    doAssert replay.checkpoint.len == 8

  block copierHeader:
    let
      rawRom = directory / "body.smc"
      headedRom = directory / "headed.smc"
    writeFile(rawRom, body)
    writeFile(headedRom, repeat('\xAA', 512) & body)
    let
      rawWriter = openCaptureWriter(directory / "crc-raw", rawRom, core, "Decompbound", "1")
      headedWriter = openCaptureWriter(directory / "crc-head", headedRom, core, "Decompbound", "1")
    rawWriter.beginSegment(DbStPrefix)
    rawWriter.capture(imageOf(red), DbStPrefix)
    rawWriter.close()
    headedWriter.beginSegment(DbStPrefix)
    headedWriter.capture(imageOf(red), DbStPrefix)
    headedWriter.close()
    let
      rawPayload = chunkPayload(readFile(pngs(rawWriter.directory)[0]), "ebSt")
      headedPayload = chunkPayload(readFile(pngs(headedWriter.directory)[0]), "ebSt")
    doAssert rawPayload[6 ..< 10] == headedPayload[6 ..< 10]
    doAssert $secureHashFile(rawRom) != $secureHashFile(headedRom)

  block envelopes:
    let writer = openCaptureWriter(directory / "wrap", rom, core, "mGBA", "1")
    writer.beginSegment("raw-state")
    writer.capture(imageOf(red), "raw-state")
    writer.close()
    let
      mrSt = readFile(pngs(writer.directory)[0])
      ebWriter = openCaptureWriter(directory / "ebwrap", rom, core, "Decompbound", "1")
    ebWriter.beginSegment(DbStPrefix)
    ebWriter.capture(imageOf(red), DbStPrefix)
    ebWriter.close()
    let ebSt = readFile(pngs(ebWriter.directory)[0])
    doAssert unwrapScreenstate("DBST-raw", romHash, coreHash) == "DBST-raw"
    doAssert unwrapScreenstate(ebSt, romHash, coreHash) == ebSt
    doAssert unwrapScreenstate(mrSt, romHash, coreHash) == "raw-state"
    expectError: discard unwrapScreenstate(mrSt, "0".repeat(40), coreHash)
    expectError: discard unwrapScreenstate(mrSt, romHash, "0".repeat(40))
    var broken = mrSt
    let index = broken.find("mrSt")
    doAssert index >= 0
    broken[index + 8] = char(broken[index + 8].uint8 xor 1)
    expectError: discard unwrapScreenstate(broken, romHash, coreHash)
    expectError: discard unwrapScreenstate("\x89PNG\r\n\x1a\ntruncated", romHash, coreHash)
    var dirty = paddedEnvelope()
    dirty[DbStPrefix.len + 16] = 'x'
    let bad = openCaptureWriter(directory / "bad-pad", rom, core, "Decompbound", "1")
    expectError: bad.beginSegment(dirty)
    bad.close()

  block writerDrain:
    let writer = openCaptureWriter(directory / "drain", rom, core, "mGBA", "1")
    writer.beginSegment("s")
    setFilePermissions(writer.directory, {fpUserRead, fpUserExec})
    var raised = false
    try:
      writer.capture(imageOf(red), "state")
      writer.close()
    except IOError: raised = true
    try: writer.close()
    except IOError: raised = true
    setFilePermissions(writer.directory, {fpUserRead, fpUserWrite, fpUserExec})
    doAssert raised

  block liveReplayBoundary:
    let writer = openCaptureWriter(directory / "live", rom, core, "mGBA", "1")
    writer.beginSegment("checkpoint")
    for _ in 0 ..< 5: writer.recordInput(256, PointerInput())
    writer.capture(imageOf(red), reason = "auto")
    let deadline = getMonoTime() + initDuration(seconds = 5)
    var sidecars: seq[string]
    while sidecars.len == 0:
      doAssert getMonoTime() < deadline
      for path in walkFiles(writer.directory / "capture_*.json"): sidecars.add(path)
      sleep(5)
    let sidecar = parseFile(sidecars[0])
    doAssert sidecar["frames"].getInt == 5
    doAssert readReplay(writer.directory / sidecar["replay"].getStr).inputs.len == 5
    writer.recordInput(0, PointerInput())
    writer.close()
    doAssert readReplay(writer.directory / "segment_0001.json").inputs.len == 6

  block bounds:
    let writer = openCaptureWriter(directory / "bounds", rom, core, "mGBA", "1")
    writer.beginSegment("c")
    writer.recordInput(0, PointerInput())
    writer.close()
    let manifestPath = writer.directory / "segment_0001.json"
    var manifest = parseJson(readFile(manifestPath))
    manifest["checkpoint"] = %"../escape.state"
    writeFile(manifestPath, $manifest)
    expectError: discard readReplay(manifestPath)
    manifest["checkpoint"] = %"segment_0001.state"
    manifest["frames"] = %10_000_001
    writeFile(manifestPath, $manifest)
    expectError: discard readReplay(manifestPath)
    manifest["frames"] = %1
    writeFile(manifestPath, $manifest)
    writeFile(writer.directory / "segment_0001.jsonl", "{\"frame\":5,\"buttons\":0}\n{\"length\":1}\n")
    expectError: discard readReplay(manifestPath)
    writeFile(writer.directory / "segment_0001.jsonl", "{\"frame\":0,\"buttons\":0}\n")
    expectError: discard readReplay(manifestPath)
    writeFile(writer.directory / "segment_0001.jsonl", "{\"length\":1}\n")
    expectError: discard readReplay(manifestPath)
    writeFile(writer.directory / "segment_0001.state", "")
    expectError: discard readReplay(manifestPath)

  block failedAppendKeepsCommittedPrefix:
    let writer = openCaptureWriter(directory / "append-failure", rom, core, "mGBA", "1")
    writer.beginSegment("checkpoint")
    writer.recordInput(0, PointerInput())
    writer.capture(imageOf(red), reason = "auto")
    let deadline = getMonoTime() + initDuration(seconds = 5)
    var ready = false
    while not ready:
      doAssert getMonoTime() < deadline
      for path in walkFiles(writer.directory / "capture_*.json"): ready = true
      sleep(5)
    let
      log = writer.directory / "segment_0001.jsonl"
      backup = writer.directory / "committed.jsonl"
      manifest = writer.directory / "segment_0001.json"
    moveFile(log, backup)
    createDir(log)
    writer.recordInput(256, PointerInput())
    writer.capture(imageOf(green), "new-state", "failed")
    var raised = false
    while not raised:
      doAssert getMonoTime() < deadline
      try: writer.recordInput(256, PointerInput())
      except IOError: raised = true
      sleep(5)
    expectError: writer.recordInput(0, PointerInput())
    expectError: writer.capture(imageOf(green), reason = "after-failure")
    expectError: writer.close()
    doAssert pngs(writer.directory).len == 1
    doAssert parseFile(manifest)["frames"].getInt == 1
    removeDir(log)
    moveFile(backup, log)
    doAssert readReplay(manifest).inputs.len == 1

main()
