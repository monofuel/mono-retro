import
  std/[dynlib, os, posix, strformat, strutils],
  ./[framebuffer, pattern]

type
  ModeInfo = object
    clock: uint32
    hdisplay, hsyncStart, hsyncEnd, htotal, hskew: uint16
    vdisplay, vsyncStart, vsyncEnd, vtotal, vscan: uint16
    refresh, flags, modeType: uint32
    name: array[32, char]
  Resources = object
    countFbs: cint
    fbs: ptr UncheckedArray[uint32]
    countCrtcs: cint
    crtcs: ptr UncheckedArray[uint32]
    countConnectors: cint
    connectors: ptr UncheckedArray[uint32]
    countEncoders: cint
    encoders: ptr UncheckedArray[uint32]
    minWidth, maxWidth, minHeight, maxHeight: uint32
  Connector = object
    id, encoderId, connectorType, typeId: uint32
    connection: cint
    mmWidth, mmHeight: uint32
    subpixel, countModes: cint
    modes: ptr UncheckedArray[ModeInfo]
    countProperties: cint
    properties: ptr UncheckedArray[uint32]
    values: ptr UncheckedArray[uint64]
    countEncoders: cint
    encoders: ptr UncheckedArray[uint32]
  Encoder = object
    id, encoderType, crtcId, possibleCrtcs, possibleClones: uint32
  Crtc = object
    id, bufferId, x, y, width, height: uint32
    modeValid: cint
    mode: ModeInfo
    gammaSize: cint
  DumbBuffer = object
    height, width, bpp, flags, handle, pitch: uint32
    size: uint64
  MapBuffer = object
    handle, padding: uint32
    offset: uint64
  FramebufferInfo = object
    id, width, height, pitch, bpp, depth, handle: uint32
  GemClose = object
    handle, padding: uint32
  DrmApi = object
    library: LibHandle
    getResources: proc(fd: cint): ptr Resources {.cdecl.}
    freeResources: proc(value: ptr Resources) {.cdecl.}
    getConnector: proc(fd: cint, id: uint32): ptr Connector {.cdecl.}
    freeConnector: proc(value: ptr Connector) {.cdecl.}
    getEncoder: proc(fd: cint, id: uint32): ptr Encoder {.cdecl.}
    freeEncoder: proc(value: ptr Encoder) {.cdecl.}
    getCrtc: proc(fd: cint, id: uint32): ptr Crtc {.cdecl.}
    freeCrtc: proc(value: ptr Crtc) {.cdecl.}
    setCrtc: proc(fd: cint, id, buffer, x, y: uint32, connectors: ptr uint32,
      count: cint, mode: ptr ModeInfo): cint {.cdecl.}
    addFb: proc(fd: cint, width, height: uint32, depth, bpp: uint8,
      pitch, handle: uint32, id: ptr uint32): cint {.cdecl.}
    removeFb: proc(fd: cint, id: uint32): cint {.cdecl.}
    getFb: proc(fd: cint, id: uint32): ptr FramebufferInfo {.cdecl.}
    freeFb: proc(value: ptr FramebufferInfo) {.cdecl.}
    setMaster, dropMaster: proc(fd: cint): cint {.cdecl.}
  DrmScreen* = ref object
    name*: string
    width*, height*: int
    rotation: int
    connector, crtc, framebuffer: uint32
    mode: ModeInfo
    original: Crtc
    originalConnectors: seq[uint32]
    buffer: DumbBuffer
    memory: pointer
    activated: bool
  DrmDisplay* = ref object
    api: DrmApi
    fd: cint
    master: bool
    screens*: seq[DrmScreen]

const
  CreateDumb = 0xc02064b2.culong
  MapDumb = 0xc01064b3.culong
  DestroyDumb = 0xc00464b4.culong
  CloseGem = 0x40086409.culong
  Connected = 1
  PreferredMode = 1'u32 shl 3
  MaximumBufferBytes = 512 * 1024 * 1024
  ConnectorNames = ["Unknown", "VGA", "DVI-I", "DVI-D", "DVI-A", "Composite",
    "SVIDEO", "LVDS", "Component", "DIN", "DP", "HDMI-A", "HDMI-B", "TV",
    "eDP", "Virtual", "DSI", "DPI", "Writeback", "SPI", "USB"]

static:
  doAssert sizeof(pointer) == 8
  doAssert sizeof(ModeInfo) == 68
  doAssert sizeof(Resources) == 80
  doAssert sizeof(Connector) == 88
  doAssert sizeof(Crtc) == 100
  doAssert sizeof(Encoder) == 20
  doAssert sizeof(DumbBuffer) == 32
  doAssert sizeof(MapBuffer) == 16
  doAssert sizeof(FramebufferInfo) == 28
  doAssert sizeof(GemClose) == 8

proc loadDrm(): DrmApi =
  ## Load DRM only when a DRM display is requested.
  result.library = loadLib("libdrm.so.2")
  if result.library == nil:
    raise newException(IOError, "Cannot load libdrm.so.2; install libdrm for DRM displays")
  template bindSymbol(field: untyped, name: string) =
    result.field = cast[type(result.field)](symAddr(result.library, name))
    if result.field == nil:
      unloadLib(result.library)
      raise newException(IOError, "Missing DRM symbol: " & name)
  bindSymbol(getResources, "drmModeGetResources")
  bindSymbol(freeResources, "drmModeFreeResources")
  bindSymbol(getConnector, "drmModeGetConnector")
  bindSymbol(freeConnector, "drmModeFreeConnector")
  bindSymbol(getEncoder, "drmModeGetEncoder")
  bindSymbol(freeEncoder, "drmModeFreeEncoder")
  bindSymbol(getCrtc, "drmModeGetCrtc")
  bindSymbol(freeCrtc, "drmModeFreeCrtc")
  bindSymbol(setCrtc, "drmModeSetCrtc")
  bindSymbol(addFb, "drmModeAddFB")
  bindSymbol(removeFb, "drmModeRmFB")
  bindSymbol(getFb, "drmModeGetFB")
  bindSymbol(freeFb, "drmModeFreeFB")
  bindSymbol(setMaster, "drmSetMaster")
  bindSymbol(dropMaster, "drmDropMaster")

proc close*(display: DrmDisplay) =
  ## Restore available scanout state and release every acquired resource.
  var errors: seq[string]
  for screen in display.screens:
    if screen.activated:
      var
        original = screen.original
        connectors = screen.originalConnectors
        enabled = original.modeValid != 0 and original.bufferId != 0
      if enabled:
        let framebuffer = display.api.getFb(display.fd, original.bufferId)
        if framebuffer == nil:
          let error = osLastError()
          enabled = false
          if error == OSErrorCode(ENOENT):
            echo "Original framebuffer retired by kernel; disabling ", screen.name, " on exit"
          else:
            errors.add "Querying original framebuffer for " & screen.name & ": " & $error
        else:
          if framebuffer.handle != 0:
            var handle = GemClose(handle: framebuffer.handle)
            if deviceIoctl(display.fd, CloseGem, addr handle) < 0:
              errors.add "Closing original GEM handle for " & screen.name
          display.api.freeFb(framebuffer)
      let
        connectorPointer = if enabled and connectors.len > 0: addr connectors[0] else: nil
        modePointer = if enabled: addr original.mode else: nil
        count = if enabled: cint(connectors.len) else: 0.cint
        buffer = if enabled: original.bufferId else: 0'u32
      if display.api.setCrtc(display.fd, screen.crtc, buffer, original.x,
          original.y, connectorPointer, count, modePointer) < 0:
        errors.add "Restoring " & screen.name
      screen.activated = false
    if screen.memory != nil:
      if munmap(screen.memory, int(screen.buffer.size)) < 0:
        errors.add "Unmapping " & screen.name
      screen.memory = nil
    if screen.framebuffer != 0:
      if display.api.removeFb(display.fd, screen.framebuffer) < 0:
        errors.add "Removing framebuffer for " & screen.name
      screen.framebuffer = 0
    if screen.buffer.handle != 0:
      if deviceIoctl(display.fd, DestroyDumb, addr screen.buffer.handle) < 0:
        errors.add "Destroying buffer for " & screen.name
      screen.buffer.handle = 0
  if display.fd >= 0:
    if display.master and display.api.dropMaster(display.fd) < 0:
      errors.add "Releasing DRM master"
    if posix.close(display.fd) < 0:
      errors.add "Closing DRM device"
    display.fd = -1
  if display.api.library != nil:
    unloadLib(display.api.library)
    display.api.library = nil
  if errors.len > 0:
    raise newException(IOError, errors.join("; "))

proc connectorName(connector: ptr Connector): string =
  ## Format the kernel connector type and instance as a stable output name.
  let prefix = if connector.connectorType < uint32(ConnectorNames.len):
    ConnectorNames[connector.connectorType] else: "Connector" & $connector.connectorType
  prefix & "-" & $connector.typeId

proc chooseCrtc*(ids: openArray[uint32], current, possible: uint32,
    unavailable: openArray[uint32]): uint32 =
  ## Prefer the current compatible controller without taking another output's controller.
  for index, id in ids:
    if index < 32 and (possible and (1'u32 shl index)) != 0 and
        id notin unavailable and id == current:
      return id
  for index, id in ids:
    if index < 32 and (possible and (1'u32 shl index)) != 0 and id notin unavailable:
      return id
  raise newException(IOError, "No independent display controller is available")

proc openDrm*(path: string, outputs: seq[string], rotation: int): DrmDisplay =
  ## Prepare independent CPU scanout buffers without changing the active display.
  result = DrmDisplay(fd: -1, api: loadDrm())
  try:
    result.fd = posix.open(path.cstring, O_RDWR or O_CLOEXEC)
    if result.fd < 0:
      raiseOSError(osLastError(), path)
    let
      api = result.api
      resources = api.getResources(result.fd)
    if resources == nil:
      raiseOSError(osLastError(), "Reading DRM resources")
    defer: api.freeResources(resources)
    var
      connectors: seq[ptr Connector]
      names: seq[string]
      crtcs: seq[uint32]
      used: seq[uint32]
      requested = outputs
    defer:
      for connector in connectors:
        api.freeConnector(connector)
    for index in 0 ..< int(resources.countCrtcs):
      crtcs.add resources.crtcs[index]
    for index in 0 ..< int(resources.countConnectors):
      let connector = api.getConnector(result.fd, resources.connectors[index])
      if connector == nil:
        raiseOSError(osLastError(), "Reading DRM connector")
      connectors.add connector
      names.add connector.connectorName()
      if outputs.len == 0 and connector.connection == Connected and connector.countModes > 0:
        requested.add names[^1]
    if requested.len == 0:
      raise newException(IOError, "No connected DRM displays")
    for name in requested:
      let index = names.find(name)
      if index < 0:
        raise newException(IOError, "DRM output not found: " & name)
      let connector = connectors[index]
      if connector.connection != Connected or connector.countModes == 0:
        raise newException(IOError, "DRM output has no connected mode: " & name)
      var
        possible = 0'u32
        current = 0'u32
      for index in 0 ..< int(connector.countEncoders):
        let encoder = api.getEncoder(result.fd, connector.encoders[index])
        if encoder == nil:
          raiseOSError(osLastError(), "Reading DRM encoder")
        possible = possible or encoder.possibleCrtcs
        if encoder.id == connector.encoderId:
          current = encoder.crtcId
        api.freeEncoder(encoder)
      var unavailable = used
      for other in connectors:
        if other.connectorName() notin requested and other.encoderId != 0:
          let encoder = api.getEncoder(result.fd, other.encoderId)
          if encoder == nil:
            raiseOSError(osLastError(), "Reading existing DRM route")
          if encoder.crtcId != 0:
            unavailable.add encoder.crtcId
          api.freeEncoder(encoder)
      let
        id = chooseCrtc(crtcs, current, possible, unavailable)
        original = api.getCrtc(result.fd, id)
      if original == nil:
        raiseOSError(osLastError(), "Saving DRM scanout")
      let screen = DrmScreen(name: name, connector: connector.id, crtc: id,
        original: original[], mode: connector.modes[0], rotation: rotation)
      api.freeCrtc(original)
      result.screens.add screen
      used.add id
      for modeIndex in 0 ..< int(connector.countModes):
        if (connector.modes[modeIndex].modeType and PreferredMode) != 0:
          screen.mode = connector.modes[modeIndex]
          break
      if screen.original.modeValid != 0:
        screen.mode = screen.original.mode
      for other in connectors:
        if other.encoderId != 0:
          let encoder = api.getEncoder(result.fd, other.encoderId)
          if encoder == nil:
            raiseOSError(osLastError(), "Saving DRM connector routing")
          if encoder.crtcId == id:
            screen.originalConnectors.add other.id
          api.freeEncoder(encoder)
      screen.width = int(if rotation in [90, 270]: screen.mode.vdisplay else: screen.mode.hdisplay)
      screen.height = int(if rotation in [90, 270]: screen.mode.hdisplay else: screen.mode.vdisplay)
      screen.buffer = DumbBuffer(width: uint32(screen.mode.hdisplay),
        height: uint32(screen.mode.vdisplay), bpp: 32)
      if deviceIoctl(result.fd, CreateDumb, addr screen.buffer) < 0:
        raiseOSError(osLastError(), "Allocating DRM scanout buffer")
      if screen.buffer.pitch < screen.buffer.width * 4 or
          screen.buffer.size < uint64(screen.buffer.pitch) * screen.buffer.height or
          screen.buffer.size > MaximumBufferBytes:
        raise newException(IOError, "Unsupported DRM buffer geometry")
      if api.addFb(result.fd, screen.buffer.width, screen.buffer.height, 24, 32,
          screen.buffer.pitch, screen.buffer.handle, addr screen.framebuffer) < 0:
        raiseOSError(osLastError(), "Registering DRM framebuffer")
      var mapping = MapBuffer(handle: screen.buffer.handle)
      if deviceIoctl(result.fd, MapDumb, addr mapping) < 0:
        raiseOSError(osLastError(), "Mapping DRM buffer")
      screen.memory = mmap(nil, int(screen.buffer.size), PROT_READ or PROT_WRITE,
        MAP_SHARED, result.fd, Off(mapping.offset))
      if screen.memory == MAP_FAILED:
        screen.memory = nil
        raiseOSError(osLastError(), "Mapping DRM scanout memory")
  except:
    result.close()
    raise

proc present*(display: DrmDisplay, index: int, canvas: Canvas) =
  ## Copy a canvas into scanout and activate its controller on the first frame.
  let screen = display.screens[index]
  if canvas.width != screen.width or canvas.height != screen.height:
    raise newException(ValueError, "Canvas does not match DRM screen")
  let destination = cast[ptr UncheckedArray[uint32]](screen.memory)
  if screen.rotation == 0:
    for row in 0 ..< canvas.height:
      copyMem(addr destination[row * int(screen.buffer.pitch) div 4],
        unsafeAddr canvas.pixels[row * canvas.width], canvas.width * 4)
  else:
    for y in 0 ..< canvas.height:
      for x in 0 ..< canvas.width:
        let point = rotatedPoint(x, y, canvas.width, canvas.height, screen.rotation)
        destination[point.y * int(screen.buffer.pitch) div 4 + point.x] = canvas.pixels[y * canvas.width + x]
  if not screen.activated:
    if not display.master:
      if display.api.setMaster(display.fd) < 0:
        raiseOSError(osLastError(), "Acquiring DRM master; another display application may be running")
      display.master = true
    if display.api.setCrtc(display.fd, screen.crtc, screen.framebuffer, 0, 0,
        addr screen.connector, 1, addr screen.mode) < 0:
      raiseOSError(osLastError(), "Displaying " & screen.name)
    screen.activated = true

proc describe*(screen: DrmScreen): string =
  ## Describe the selected connector, logical geometry and controller.
  &"{screen.name}: {screen.width}x{screen.height}, CRTC {screen.crtc}, rotation {screen.rotation}"
