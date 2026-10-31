import
  std/os,
  pixie, windy,
  ./[display, playerds, settings]

when HasDrm:
  import windy/drmpixels
when HasX11:
  import windy/x11pixels

type
  PlayerVideoMode* = enum
    AutoVideo, CpuVideo, GpuVideo
  PlayerCrops* = array[2, tuple[x, y, width, height: int]]
  PlayerGpu* = ref object
    when HasDrm:
      pair: DrmPixelPair
    when HasX11:
      desktop: seq[X11PixelPresenter]
      windows: seq[Window]
      pending: array[2, bool]
    gameScale: int
    presented: bool
    sequence: uint64
    crops: PlayerCrops

proc parseVideoMode*(value: string): PlayerVideoMode =
  ## Select automatic GPU presentation or an explicit comparison path.
  case value
  of "auto": AutoVideo
  of "cpu": CpuVideo
  of "gpu": GpuVideo
  else: raise newException(ValueError, "Video mode must be auto, cpu or gpu")

proc useGpuVideo*(mode: PlayerVideoMode, backend: string, outputs, rotation: int,
    panfrost: bool): bool =
  ## Select synchronized desktop textures or the proven native GPU pair.
  let
    desktop = backend == "x11" and outputs in 1 .. 2 and rotation == 0
    native = backend == "drm" and outputs == 2 and rotation == 0
  case mode
  of CpuVideo: false
  of AutoVideo: desktop or (native and panfrost)
  of GpuVideo:
    if not (desktop or native):
      raise newException(ValueError, "GPU video requires X11 windows or two unrotated DRM outputs")
    true

proc playerCrops*(width, height, panelWidth, panelHeight, active: int,
    separate: bool): PlayerCrops =
  ## Assign source crops to physical outputs without splitting pixel storage.
  if width <= 0 or height <= 0 or active notin 0..1:
    raise newException(ValueError, "Invalid GPU player frame or active screen")
  if separate:
    validateDsFrame(width, height, panelWidth, panelHeight)
    result[0] = (0, 0, panelWidth, panelHeight)
    result[1] = (0, panelHeight, panelWidth, panelHeight)
  else:
    result[active] = (0, 0, width, height)

proc panfrostAvailable(): bool =
  ## Detect the source-kernel render driver without changing GPU configuration.
  for path in walkPattern("/sys/class/drm/renderD*/device/driver"):
    if symlinkExists(path) and expandSymlink(path).extractFilename == "panfrost":
      return true

proc close*(gpu: PlayerGpu) =
  ## Release GPU presenters before the input/display windows.
  if gpu == nil: return
  when HasX11:
    for presenter in gpu.desktop: presenter.close()
    gpu.desktop.setLen(0)
    gpu.windows.setLen(0)
  when HasDrm: gpu.pair.close()

proc openPlayerGpu*(mode: PlayerVideoMode, screen: Display, settings: Settings,
    gameScale = 0): PlayerGpu =
  ## Keep CPU paths unchanged; selected GPU initialization errors remain visible.
  if not useGpuVideo(mode, settings.displayBackend(), screen.count(), settings.rotation,
      mode == AutoVideo and panfrostAvailable()):
    return nil
  when HasX11:
    if settings.displayBackend() == "x11":
      result = PlayerGpu(gameScale: gameScale)
      try:
        for index in 0 ..< screen.count():
          let window = screen.window(index)
          result.windows.add(window)
          result.desktop.add(newX11PixelPresenter(window))
        for presenter in result.desktop: presenter.drawPixels(nil, PixelRegion())
        for presenter in result.desktop: presenter.swap()
        stderr.writeLine("Video presentation: X11 GPU textures.")
      except:
        result.close()
        raise
      return
  when HasDrm:
    result = PlayerGpu(pair: newDrmPixelPair(screen.window(0), screen.window(1)))
    try:
      result.pair.presentPixels(nil, [PixelRegion(), PixelRegion()])
    except:
      result.close()
      raise
  else:
    raise newException(ValueError, "DRM GPU video was not compiled")

proc presentDesktop(gpu: PlayerGpu, image: Image, crops: PlayerCrops,
    revision: uint64, changed: bool, fitUi: int) =
  ## Draw every back buffer before swapping, retaining native textures on duplicate frames.
  when HasX11:
    var drawn: array[2, bool]
    for index, presenter in gpu.desktop:
      let
        window = gpu.windows[index]
        size = window.framebufferSize
        crop = crops[index]
      if window.minimized or not window.visible or size.x <= 0 or size.y <= 0:
        gpu.pending[index] = true
        continue
      presenter.drawPixels(image, PixelRegion(x: crop.x, y: crop.y,
        width: crop.width, height: crop.height),
        changed = not gpu.presented or changed or gpu.pending[index],
        scale = (if index == 0: gpu.gameScale else: 0), fitDown = index == fitUi)
      gpu.pending[index] = false
      drawn[index] = true
    for index, presenter in gpu.desktop:
      if drawn[index]: presenter.swap()
    gpu.presented = true
    gpu.sequence = revision
    gpu.crops = crops

proc presentComposition*(gpu: PlayerGpu, image: Image, crops: PlayerCrops,
    revision: uint64, changed = true, fitUi = -1) =
  ## Present app-owned UI crops through the selected GPU backend.
  if gpu == nil or image == nil: return
  for crop in crops:
    if crop.x < 0 or crop.y < 0 or crop.width < 0 or crop.height < 0 or
        (crop.width == 0) != (crop.height == 0) or crop.x > image.width or
        crop.y > image.height or crop.width > image.width - crop.x or
        crop.height > image.height - crop.y:
      raise newException(ValueError, "Invalid GPU composition crop")
  when HasX11:
    if gpu.desktop.len > 0:
      gpu.presentDesktop(image, crops, revision, changed, fitUi)
      return
  if gpu.presented and gpu.crops == crops and
      (gpu.sequence == revision or not changed):
    gpu.sequence = revision
    return
  when HasDrm:
    var regions: array[2, PixelRegion]
    for index, crop in crops:
      regions[index] = PixelRegion(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
    gpu.pair.presentPixels(image, regions)
    gpu.presented = true
    gpu.sequence = revision
    gpu.crops = crops

proc present*(gpu: PlayerGpu, image: Image, sequence: uint64, active: int,
    separate: bool, panelWidth, panelHeight: int, changed = true) =
  ## Route simple game frames through the same presentation path as UI compositions.
  if gpu == nil or image == nil: return
  gpu.presentComposition(image, playerCrops(image.width, image.height,
    panelWidth, panelHeight, active, separate), sequence, changed)
