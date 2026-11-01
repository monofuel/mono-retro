import
  std/[os, tempfiles],
  pixie,
  retro/[overlayui, pausemenu, playeroverlay, playerslots]

proc main() =
  ## Verify real slot navigation, confirmations and dual-screen composition with synthetic data.
  let
    root = createTempDir("pause-menu-", "")
    rom = root / "game.test"
    core = root / "core.so"
  defer: removeDir(root)
  writeFile(rom, "synthetic ROM")
  writeFile(core, "synthetic core")
  let
    store = newStateStore(root / "saves", rom, core, root / "captures", root / "shots")
    menu = newPauseMenu(store, true, true)
    image = newImage(256, 448)
  image.fill(rgbx(25, 60, 90, 255))
  doAssert not menu.handle(OcNext)
  doAssert not menu.handle(OcActivate)
  doAssert menu.page == PauseSave and menu.entries.len == 10
  doAssert not menu.handle(OcActivate)
  doAssert menu.takeRequest() == PauseRequest(kind: PauseSaveSlot, slot: 1)
  store.saveSlot(1, image, "synthetic machine state")
  menu.complete("Saved")
  doAssert not menu.handle(OcActivate)
  doAssert menu.page == PauseConfirm
  doAssert not menu.handle(OcActivate)
  doAssert menu.page == PauseSave and menu.takeRequest().kind == PauseNothing
  doAssert not menu.handle(OcActivate)
  doAssert not menu.handle(OcNext)
  doAssert not menu.handle(OcActivate)
  doAssert menu.takeRequest().kind == PauseSaveSlot
  menu.openRoot()
  doAssert not menu.handle(OcNext)
  doAssert not menu.handle(OcNext)
  doAssert not menu.handle(OcActivate)
  doAssert menu.page == PauseLoad
  doAssert not menu.handle(OcActivate)
  doAssert menu.page == PauseConfirm
  doAssert not menu.handle(OcNext)
  doAssert not menu.handle(OcActivate)
  doAssert menu.takeRequest().path == store.slotPath(1)
  menu.openRoot()
  doAssert not menu.pointer(30, 68 + 2 * 46 + 10)
  doAssert menu.page == PauseLoad
  menu.switchSource()
  doAssert menu.page == PauseRecent and menu.entries.len == 0
  let overlay = newOverlayState()
  overlay.configurePauseMenu(store, true, true)
  doAssert overlay.handleOverlay(OverlayToggle) == OverlayOpened
  let composed = overlay.composeOverlay(image, 1, OverlaySeparate, true, 256, 224)
  doAssert composed.modal and composed.uiOutput == 1
  doAssert composed.crops[0].height == 224
  doAssert composed.sourceImage.data[128] == image.data[0]
  doAssert overlay.handleOverlay(OverlayNext) == OverlayChanged
  doAssert overlay.handleOverlay(OverlayActivate) == OverlayChanged
  doAssert overlay.pause.page == PauseSave
  discard overlay.handleOverlay(OverlayToggle)
  let indicator = newImage(200, 40)
  indicator.fill(rgbx(99, 88, 77, 255))
  overlay.setVolumeOverlay(indicator, true, 1)
  let live = overlay.composeOverlay(image, 1, OverlaySeparate, true, 256, 224)
  doAssert not live.modal
  doAssert live.sourceImage != image
  doAssert live.sourceImage.data[4 * live.sourceImage.width + 4 + 224 * live.sourceImage.width] == indicator.data[0]
  overlay.setVolumeOverlay(nil, false, 1)
  doAssert overlay.composeOverlay(image, 1, OverlaySeparate, true, 256, 224, changed = false).sourceImage == image
  let unsupported = newPauseMenu(store, false, false)
  discard unsupported.handle(OcNext)
  discard unsupported.handle(OcActivate)
  doAssert unsupported.page == PauseRoot and unsupported.message.len > 0

main()
