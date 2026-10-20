import
  std/[os, posix],
  ./[drm, framebuffer, pattern, settings]

type
  Display* = ref object
    fb: Framebuffer
    drm: DrmDisplay

proc displayBackend*(settings: Settings): string =
  ## Recognize framebuffer character devices when choosing the automatic backend.
  if settings.display != "auto":
    return settings.display
  var status: Stat
  if stat(settings.framebuffer.cstring, status) == 0:
    if not S_ISCHR(status.st_mode):
      raise newException(ValueError, "Framebuffer path is not a character device")
    return "fbdev"
  let error = osLastError()
  if error notin [OSErrorCode(ENOENT), OSErrorCode(ENOTDIR)]:
    raiseOSError(error, settings.framebuffer)
  "drm"

proc openDisplay*(settings: Settings): Display =
  ## Open the configured native display backend.
  result = Display()
  let backend = settings.displayBackend()
  if backend == "fbdev":
    result.fb = openFramebuffer(settings.framebuffer, settings.rotation)
  else:
    result.drm = openDrm(settings.drmDevice, settings.outputs, settings.rotation)

proc count*(display: Display): int =
  ## Count independently addressable screens.
  if display.fb != nil: 1 else: display.drm.screens.len

proc width*(display: Display, index = 0): int =
  ## Return a screen's logical width after rotation.
  if display.fb != nil: display.fb.width else: display.drm.screens[index].width

proc height*(display: Display, index = 0): int =
  ## Return a screen's logical height after rotation.
  if display.fb != nil: display.fb.height else: display.drm.screens[index].height

proc present*(display: Display, canvas: Canvas, index = 0) =
  ## Send a canvas to the selected screen.
  if display.fb != nil: display.fb.present(canvas)
  else: display.drm.present(index, canvas)

proc describe*(display: Display, index: int): string =
  ## Describe the selected native screen.
  if display.fb != nil: display.fb.describe()
  else: display.drm.screens[index].describe()

proc close*(display: Display) =
  ## Restore display state where available and release native resources.
  if display.fb != nil: display.fb.close()
  elif display.drm != nil: display.drm.close()
