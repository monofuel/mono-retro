import
  std/[json, os, sequtils, sha1, strutils, tempfiles],
  pixie, zippy,
  retro/[playercapture, playerslots]

const
  PngSignature = "\x89PNG\r\n\x1a\n"
  DbStState = "DBST" & "\x02\x00\x00\x00" & "synthetic state"

proc imageOf(color: ColorRGBX): Image =
  ## Create a tiny deterministic screenshot for storage fixtures.
  result = newImage(2, 2)
  result.fill(color)

proc readU32be(data: string, offset: int): uint32 =
  ## Read one PNG chunk length.
  (data[offset].uint8.uint32 shl 24) or (data[offset + 1].uint8.uint32 shl 16) or
    (data[offset + 2].uint8.uint32 shl 8) or data[offset + 3].uint8.uint32

proc readU32le(data: string, offset: int): uint32 =
  ## Read one embedded screenstate word.
  data[offset].uint8.uint32 or (data[offset + 1].uint8.uint32 shl 8) or
    (data[offset + 2].uint8.uint32 shl 16) or (data[offset + 3].uint8.uint32 shl 24)

proc chunkPayload(png, kind: string): string =
  ## Return one state chunk payload from a synthetic PNG.
  doAssert png.startsWith(PngSignature)
  var position = PngSignature.len
  while position + 12 <= png.len:
    let length = readU32be(png, position).int
    if png[position + 4 ..< position + 8] == kind:
      return png[position + 8 ..< position + 8 + length]
    position += 12 + length
  raise newException(ValueError, "Missing PNG chunk: " & kind)

template expectError(body: untyped) =
  ## Require invalid public API use to raise a regular Nim exception.
  var raised = false
  try:
    body
  except CatchableError:
    raised = true
  doAssert raised

proc writeMetadata(directory, romHash, coreHash: string) =
  ## Write the minimal capture session identity document used by discovery.
  createDir(directory)
  writeFile(directory / "metadata.json", $(%*{"romHash": romHash, "coreHash": coreHash}))

proc main() =
  ## Exercise isolated slots, lazy recent discovery, and PNG corruption handling.
  let directory = createTempDir("player-slots-", "")
  defer: removeDir(directory)
  let
    saveRoot = directory / "saves"
    captures = directory / "captures"
    screenshots = directory / "screenshots"
    rom = directory / "game.smc"
    otherRom = directory / "other.smc"
    core = directory / "core.so"
    otherCore = directory / "other-core.so"
  writeFile(rom, repeat('R', 1024))
  writeFile(otherRom, repeat('S', 1024))
  writeFile(core, "core bytes")
  writeFile(otherCore, "other core bytes")
  let
    store = newStateStore(saveRoot, rom, core, captures, screenshots)
    otherStore = newStateStore(saveRoot, otherRom, core, captures, screenshots)
    red = imageOf(rgbx(255, 0, 0, 255))
    green = imageOf(rgbx(0, 255, 0, 255))
    romHash = $secureHashFile(rom)
    coreHash = $secureHashFile(core)
    otherCoreHash = $secureHashFile(otherCore)

  block fixedSlotsAndRoundTrips:
    doAssert store.slots.len == 10
    for index, entry in store.slots:
      doAssert entry.slot == index + 1
      doAssert entry.path == store.slotPath(index + 1)
      doAssert entry.unavailable.len == 0
    expectError: discard store.slotPath(0)
    expectError: store.saveSlot(11, red, "state")
    store.saveSlot(1, red, "generic state")
    doAssert unwrapScreenstate(readFile(store.slotPath(1)), romHash, coreHash) == "generic state"
    store.saveSlot(2, green, DbStState)
    let eb = chunkPayload(readFile(store.slotPath(2)), "ebSt")
    doAssert eb.startsWith("EBSS")
    doAssert readU32le(eb, 10).int == DbStState.len
    doAssert uncompress(eb[14 .. ^1], dfDeflate) == DbStState
    let thumbnail = store.slots[0].thumbnail()
    doAssert thumbnail != nil and thumbnail.width == 2 and thumbnail.height == 2

  block overwriteAndIsolation:
    let path = store.slotPath(1)
    let previous = readFile(path)
    expectError: store.saveSlot(1, nil, "replacement")
    doAssert readFile(path) == previous
    doAssert store.slotPath(1) != otherStore.slotPath(1)
    doAssert not fileExists(otherStore.slotPath(1))

  block recentsFilteringDeduplicationAndCorruption:
    let session = captures / "session-one"
    writeMetadata(session, romHash, coreHash)
    let first = encodeScreenstatePng(red, "recent generic", romHash, coreHash,
      normalizedRomCrc32(readFile(rom)), false)
    writeFile(session / "one.png", first)
    createDir(screenshots)
    copyFile(session / "one.png", screenshots / "duplicate.png")
    writeFile(screenshots / "bound.png", encodeScreenstatePng(green, DbStState, romHash,
      coreHash, normalizedRomCrc32(readFile(rom)), true))
    writeFile(screenshots / "other-core.png", encodeScreenstatePng(red, "wrong core", romHash,
      otherCoreHash, normalizedRomCrc32(readFile(rom)), false))
    writeFile(screenshots / "plain5sec.png", red.encodeImage(PngFormat))
    var broken = first
    broken.setLen(broken.len - 1)
    writeFile(screenshots / "broken.png", broken)
    let entries = store.recent
    doAssert entries.len == 4
    doAssert entries.countIt(it.path.endsWith("one.png") or it.path.endsWith("duplicate.png")) == 1
    doAssert entries.anyIt(it.path.endsWith("bound.png") and it.unavailable.len == 0)
    doAssert entries.anyIt(it.path.endsWith("other-core.png") and it.unavailable.contains("core build"))
    doAssert entries.anyIt(it.path.endsWith("broken.png") and it.unavailable.len > 0)
    doAssert entries.allIt(not it.path.endsWith("plain5sec.png"))

when isMainModule:
  main()
