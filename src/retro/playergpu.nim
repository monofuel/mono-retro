import
  std/os,
  pixie, windy,
  ./[display, playerds, settings]

when HasDrm:
  import windy/drmpixels

type
  PlayerVideoMode* = enum
    AutoVideo, CpuVideo, GpuVideo
  PlayerCrops* = array[2, tuple[x, y, width, height: int]]
  PlayerGpu* = ref object
    when HasDrm:
      pair: DrmPixelPair
    presented: bool
    sequence: uint64
    active: int
    composition: bool
    crops: PlayerCrops

proc parseVideoMode*(value: string): PlayerVideoMode =
  ## Select automatic native GPU use or an explicit comparison path.
  case value
  of "auto": AutoVideo
  of "cpu": CpuVideo
  of "gpu": GpuVideo
  else: raise newException(ValueError, "Video mode must be auto, cpu or gpu")

proc useGpuVideo*(mode: PlayerVideoMode, backend: string, outputs, rotation: int,
    panfrost: bool): bool =
  ## Enable the proven native pair; explicit unsupported requests fail.
  let supported = backend == "drm" and outputs == 2 and rotation == 0
  case mode
  of CpuVideo: false
  of AutoVideo: supported and panfrost
  of GpuVideo:
    if not supported:
      raise newException(ValueError, "GPU video requires two unrotated DRM outputs")
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
  ## Release the GPU pair before the input/display windows.
  if gpu == nil: return
  when HasDrm: gpu.pair.close()

proc openPlayerGpu*(mode: PlayerVideoMode, screen: Display, settings: Settings): PlayerGpu =
  ## Keep CPU paths unchanged; selected GPU initialization errors remain visible.
  if not useGpuVideo(mode, settings.displayBackend(), screen.count(), settings.rotation,
      mode == AutoVideo and panfrostAvailable()):
    return nil
  when HasDrm:
    result = PlayerGpu(pair: newDrmPixelPair(screen.window(0), screen.window(1)))
    try:
      result.pair.presentPixels(nil, [PixelRegion(), PixelRegion()])
    except:
      result.close()
      raise
  else:
    raise newException(ValueError, "DRM GPU video was not compiled")

proc present*(gpu: PlayerGpu, image: Image, sequence: uint64, active: int,
    separate: bool, panelWidth, panelHeight: int, changed = true) =
  ## Upload one owned core frame, retaining scanout for duplicate callbacks.
  if gpu == nil or image == nil: return
  if gpu.presented and not gpu.composition and gpu.active == active and
      (gpu.sequence == sequence or not changed):
    gpu.sequence = sequence
    return
  when HasDrm:
    let crops = playerCrops(image.width, image.height, panelWidth, panelHeight, active, separate)
    var regions: array[2, PixelRegion]
    for index, crop in crops:
      regions[index] = PixelRegion(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
    gpu.pair.presentPixels(image, regions)
    gpu.presented = true
    gpu.sequence = sequence
    gpu.active = active
    gpu.composition = false

proc presentComposition*(gpu: PlayerGpu, image: Image, crops: PlayerCrops,
    revision: uint64, changed = true) =
  ## Present app-owned UI crops without changing the paired GPU display backend.
  if gpu == nil or image == nil: return
  for crop in crops:
    if crop.x < 0 or crop.y < 0 or crop.width < 0 or crop.height < 0 or
        (crop.width == 0) != (crop.height == 0) or crop.x > image.width or
        crop.y > image.height or crop.width > image.width - crop.x or
        crop.height > image.height - crop.y:
      raise newException(ValueError, "Invalid GPU composition crop")
  if gpu.presented and gpu.composition and gpu.crops == crops and
      (gpu.sequence == revision or not changed):
    gpu.sequence = revision
    return
  when HasDrm:
    var regions: array[2, PixelRegion]
    for index, crop in crops:
      regions[index] = PixelRegion(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
    gpu.pair.presentPixels(image, regions)
    gpu.presented = true
    gpu.composition = true
    gpu.sequence = revision
    gpu.crops = crops
