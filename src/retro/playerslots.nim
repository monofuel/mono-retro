import
  std/[algorithm, json, os, sha1, strutils, tables, times],
  pixie,
  ./[playercapture, playersave]

const
  PngSignature = "\x89PNG\r\n\x1a\n"
  PngSigLen = 8
  EbStType = "ebSt"
  MrStType = "mrSt"
  EbSsMagic = "EBSS"
  MrSsMagic = "MRSS"
  Sha1Size = 20
  MrStHeaderLen = 4 + 2 + Sha1Size + Sha1Size + 4
  EbStHeaderLen = 4 + 2 + 4 + 4
  MaxStateBytes = 64 * 1024 * 1024
  MaxEmbeddedBytes = MaxStateBytes + 1024 * 1024
  MaxPngBytes = 96 * 1024 * 1024
  MaxThumbnailPngBytes = 32 * 1024 * 1024
  MaxThumbnailDimension = 8192
  MaxThumbnailPixels = 16 * 1024 * 1024
  ChunkBufferBytes = 64 * 1024
  SlotCount = 10

type
  StateEntry* = object
    path*: string
    title*: string
    timestamp*: Time
    unavailable*: string
    slot*: int
    thumbnail*: Image
    fingerprint: string
  StateStore* = ref object
    saveDirectory, captureDirectory, screenstateDirectory: string
    romHash, coreHash: string
    romCrc: uint32
  StateKind = enum
    NoState, EbState, MrState
  PngProbe = object
    kind: StateKind
    valid, romMatches, coreMatches, sawIend: bool
    romCrc: uint32
    problem, signature, pixels: string

const CrcTable = block:
  var table: array[256, uint32]
  for index in 0 ..< table.len:
    var value = index.uint32
    for bit in 0 ..< 8:
      value = (value shr 1) xor (if (value and 1) != 0: 0xedb88320'u32 else: 0'u32)
    table[index] = value
  table

proc addU32be(data: var string, value: uint32) =
  ## Append one big-endian PNG word.
  data.add char((value shr 24) and 0xff)
  data.add char((value shr 16) and 0xff)
  data.add char((value shr 8) and 0xff)
  data.add char(value and 0xff)

proc readU16le(data: string, offset: int): uint16 =
  ## Read one little-endian screenstate word.
  data[offset].uint8.uint16 or (data[offset + 1].uint8.uint16 shl 8)

proc readU32be(data: string, offset: int): uint32 =
  ## Read one big-endian PNG word.
  (data[offset].uint8.uint32 shl 24) or (data[offset + 1].uint8.uint32 shl 16) or
    (data[offset + 2].uint8.uint32 shl 8) or data[offset + 3].uint8.uint32

proc readU32le(data: string, offset: int): uint32 =
  ## Read one little-endian screenstate word.
  data[offset].uint8.uint32 or (data[offset + 1].uint8.uint32 shl 8) or
    (data[offset + 2].uint8.uint32 shl 16) or (data[offset + 3].uint8.uint32 shl 24)

proc crcUpdate(crc: uint32, data: string): uint32 =
  ## Update a PNG CRC accumulator without retaining the complete chunk.
  result = crc
  for byte in data:
    result = CrcTable[(result xor byte.uint8.uint32) and 0xff] xor (result shr 8)

proc readExactly(file: File, count: int): string =
  ## Read exactly count bytes or reject a truncated PNG.
  if count == 0: return
  result = newString(count)
  if file.readBuffer(addr result[0], count) != count:
    raise newException(ValueError, "Truncated PNG chunk")

proc hexOf(data: string, offset: int): string =
  ## Format one raw SHA1 digest as uppercase hexadecimal.
  for index in offset ..< offset + Sha1Size:
    result.add toHex(int(data[index].uint8), 2)

proc fitsThumbnail(width, height: int): bool =
  ## True when a PNG image can be decoded within the thumbnail pixel bound.
  width > 0 and height > 0 and width <= MaxThumbnailDimension and
    height <= MaxThumbnailDimension and width.int64 * height.int64 <= MaxThumbnailPixels

proc acceptsChunkPixels(kind: string): bool =
  ## True for the PNG chunks required to decode display pixels.
  kind in ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"]

proc inspectPng(path, expectedRomHash, expectedCoreHash: string, includePixels: bool,
    probe: var PngProbe) =
  ## Stream-validate a state PNG and optionally retain only rendering chunks.
  let size = getFileSize(path)
  if size < PngSigLen or size > MaxPngBytes:
    raise newException(ValueError, "PNG file size is out of bounds")
  let file = open(path, fmRead)
  try:
    if file.readExactly(PngSigLen) != PngSignature:
      raise newException(ValueError, "Not a PNG")
    if includePixels: probe.pixels = PngSignature
    var
      first = true
      width = 0
      height = 0
      stateChunks = 0
    while file.getFilePos < size:
      let lengthBytes = file.readExactly(4)
      let length64 = readU32be(lengthBytes, 0).int64
      if length64 > size - file.getFilePos - 8:
        raise newException(ValueError, "PNG chunk length is out of bounds")
      if length64 > MaxPngBytes:
        raise newException(ValueError, "PNG chunk exceeds the file limit")
      let
        length = length64.int
        kind = file.readExactly(4)
        retain = includePixels and acceptsChunkPixels(kind)
      if retain: probe.pixels.add(lengthBytes & kind)
      if first and kind != "IHDR":
        raise newException(ValueError, "PNG must begin with IHDR")
      first = false
      var
        crc = crcUpdate(0xffffffff'u32, kind)
        header = ""
        remaining = length
      while remaining > 0:
        let part = file.readExactly(min(remaining, ChunkBufferBytes))
        crc = crcUpdate(crc, part)
        if kind in ["IHDR", EbStType, MrStType] and header.len < MrStHeaderLen:
          let take = min(MrStHeaderLen - header.len, part.len)
          header.add part[0 ..< take]
        if retain:
          if probe.pixels.len + part.len > MaxThumbnailPngBytes:
            raise newException(ValueError, "Thumbnail PNG data exceeds the limit")
          probe.pixels.add(part)
        remaining -= part.len
      let storedCrc = readU32be(file.readExactly(4), 0)
      if not crc == not storedCrc:
        # Keep enough identity information to show a corrupted state for its own game.
        if kind == EbStType and header.len >= EbStHeaderLen and header.startsWith(EbSsMagic):
          probe.kind = EbState
          probe.romCrc = readU32le(header, 6)
        elif kind == MrStType and header.len >= MrStHeaderLen and header.startsWith(MrSsMagic):
          probe.kind = MrState
          probe.romMatches = expectedRomHash.len == 0 or
            hexOf(header, 6).toLowerAscii == expectedRomHash.toLowerAscii
          probe.coreMatches = expectedCoreHash.len == 0 or
            hexOf(header, 6 + Sha1Size).toLowerAscii == expectedCoreHash.toLowerAscii
        raise newException(ValueError, "PNG chunk checksum mismatch")
      if retain: probe.pixels.addU32be(storedCrc)
      if kind == "IHDR":
        if length != 13:
          raise newException(ValueError, "PNG IHDR has an invalid length")
        width = readU32be(header, 0).int
        height = readU32be(header, 4).int
        if not fitsThumbnail(width, height):
          raise newException(ValueError, "PNG dimensions exceed the thumbnail limit")
      elif kind in [EbStType, MrStType]:
        inc stateChunks
        if stateChunks > 1 or length > MaxEmbeddedBytes + MrStHeaderLen:
          raise newException(ValueError, "PNG has an invalid embedded state")
        if kind == EbStType:
          probe.kind = EbState
          if header.len < EbStHeaderLen or not header.startsWith(EbSsMagic) or
              readU16le(header, 4) == 0 or readU32le(header, 10).int > MaxStateBytes:
            raise newException(ValueError, "Malformed ebSt screenstate")
          probe.romCrc = readU32le(header, 6)
        else:
          probe.kind = MrState
          if header.len < MrStHeaderLen or not header.startsWith(MrSsMagic) or
              readU16le(header, 4) != 1'u16 or readU32le(header, 46).int > MaxStateBytes:
            raise newException(ValueError, "Malformed mrSt screenstate")
          let romHash = hexOf(header, 6)
          let coreHash = hexOf(header, 6 + Sha1Size)
          probe.romMatches = expectedRomHash.len == 0 or romHash.toLowerAscii == expectedRomHash.toLowerAscii
          probe.coreMatches = expectedCoreHash.len == 0 or coreHash.toLowerAscii == expectedCoreHash.toLowerAscii
        probe.signature = kind & ":" & $length & ":" & $storedCrc
      elif kind == "IEND":
        if length != 0 or file.getFilePos != size:
          raise newException(ValueError, "Malformed PNG end chunk")
        probe.sawIend = true
    if not probe.sawIend:
      raise newException(ValueError, "PNG has no IEND chunk")
    if probe.kind == NoState:
      return
    probe.valid = true
  finally:
    file.close()

proc probeEntry(path, expectedRomHash, expectedCoreHash: string, expectedRomCrc: uint32): PngProbe =
  ## Inspect one candidate while retaining enough identity data for unavailable entries.
  try:
    inspectPng(path, expectedRomHash, expectedCoreHash, false, result)
  except CatchableError as error:
    result.problem = error.msg
  if result.kind == EbState:
    # ebSt identifies the normalized ROM by CRC rather than SHA1.
    result.romMatches = result.romCrc == expectedRomCrc

proc timestampOf(path: string): Time =
  ## Return a capture's filesystem timestamp, falling back to the Unix epoch.
  try:
    getLastModificationTime(path)
  except OSError:
    fromUnix(0)

proc metadataMatches(path, expectedRomHash: string): bool =
  ## Check a capture session's local metadata ROM identity before scanning its PNGs.
  let metadata = path.parentDir / "metadata.json"
  if not fileExists(metadata): return false
  try:
    let document = parseJson(readFile(metadata))
    document.kind == JObject and document.hasKey("romHash") and
      document["romHash"].kind == JString and
      document["romHash"].getStr.toLowerAscii == expectedRomHash.toLowerAscii
  except CatchableError:
    false

proc entryFor(path: string, probe: PngProbe): StateEntry =
  ## Create a lazy state entry without decoding its thumbnail or state bytes.
  result = StateEntry(path: path, title: path.extractFilename,
    timestamp: timestampOf(path), slot: 0, fingerprint: probe.signature)
  if not probe.valid:
    result.unavailable = if probe.problem.len > 0: probe.problem else: "Invalid screenstate PNG"
  elif probe.kind == MrState and not probe.coreMatches:
    result.unavailable = "Screenstate core build does not match"

proc collectRecent(store: StateStore, root: string, requireMetadata: bool,
    entries: var seq[StateEntry]) =
  ## Collect matching state screenshots under one root without loading image pixels.
  if root.len == 0 or not dirExists(root): return
  for path in walkDirRec(root):
    if path.splitFile.ext.toLowerAscii != ".png": continue
    if requireMetadata and not metadataMatches(path, store.romHash): continue
    let probe = probeEntry(path, store.romHash, store.coreHash, store.romCrc)
    if probe.kind == NoState or not probe.romMatches: continue
    entries.add(entryFor(path, probe))

proc newStateStore*(saveDirectory, romPath, corePath, captureDirectory,
    screenstateDirectory: string): StateStore =
  ## Create state storage for one ROM and core build without opening the player UI.
  if not fileExists(romPath):
    raise newException(IOError, "Missing ROM: " & romPath)
  if not fileExists(corePath):
    raise newException(IOError, "Missing core: " & corePath)
  let rom = readFile(romPath)
  StateStore(saveDirectory: absolutePath(saveDirectory),
    captureDirectory: (if captureDirectory.len > 0: absolutePath(captureDirectory) else: ""),
    screenstateDirectory: (if screenstateDirectory.len > 0: absolutePath(screenstateDirectory) else: ""),
    romHash: $secureHash(rom),
    coreHash: $secureHashFile(corePath), romCrc: normalizedRomCrc32(rom))

proc slotPath*(store: StateStore, slot: int): string =
  ## Return a ROM-isolated fixed slot PNG path, rejecting slots outside one through ten.
  if store == nil:
    raise newException(ValueError, "State store is missing")
  if slot notin 1 .. SlotCount:
    raise newException(ValueError, "Save slot must be between 1 and 10")
  store.saveDirectory / "states" / store.romHash / ("slot-" & intToStr(slot, 2) & ".png")

proc slots*(store: StateStore): seq[StateEntry] =
  ## List exactly ten fixed save slots without decoding thumbnails or state payloads.
  if store == nil:
    raise newException(ValueError, "State store is missing")
  for slot in 1 .. SlotCount:
    let path = store.slotPath(slot)
    var entry = StateEntry(path: path, title: "Slot " & $slot, slot: slot)
    if fileExists(path):
      let probe = probeEntry(path, store.romHash, store.coreHash, store.romCrc)
      entry.timestamp = timestampOf(path)
      if probe.kind == NoState or not probe.romMatches:
        entry.unavailable = if probe.problem.len > 0: probe.problem else: "State does not match this ROM"
      elif not probe.valid:
        entry.unavailable = probe.problem
      elif probe.kind == MrState and not probe.coreMatches:
        entry.unavailable = "Screenstate core build does not match"
    result.add(entry)

proc recent*(store: StateStore): seq[StateEntry] =
  ## Discover matching embedded-state captures newest first, deduplicated by state chunk signature.
  if store == nil:
    raise newException(ValueError, "State store is missing")
  store.collectRecent(store.captureDirectory, true, result)
  store.collectRecent(store.screenstateDirectory, false, result)
  result.sort(proc(left, right: StateEntry): int = cmp(right.timestamp, left.timestamp))
  var seen: Table[string, bool]
  var unique: seq[StateEntry]
  for entry in result:
    let signature = if entry.unavailable.len == 0 and entry.fingerprint.len > 0:
      entry.fingerprint else: entry.path
    if signature notin seen:
      seen[signature] = true
      unique.add(entry)
  unique

proc thumbnail*(entry: StateEntry): Image =
  ## Decode only validated PNG rendering chunks for one requested entry thumbnail.
  if entry.path.len == 0 or entry.unavailable.len > 0 or not fileExists(entry.path): return
  var probe: PngProbe
  inspectPng(entry.path, "", "", true, probe)
  if probe.valid and probe.pixels.len > 0:
    result = decodeImage(probe.pixels)

proc saveSlot*(store: StateStore, slot: int, image: Image, state: string) =
  ## Atomically replace one fixed slot with a self-contained ebSt or mrSt state PNG.
  if store == nil:
    raise newException(ValueError, "State store is missing")
  let path = store.slotPath(slot)
  createDir(path.parentDir)
  let decompbound = state.len >= 4 and state[0 ..< 4] == "DBST"
  writeSave(path, encodeScreenstatePng(image, state, store.romHash, store.coreHash,
    store.romCrc, decompbound))
