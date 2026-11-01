import
  std/[os, sha1, tempfiles],
  pixie,
  retro/[playercapture, playerslots, playerworker]

proc main() =
  ## Prove slot state and pixels belong to the same prefetched frame without enabling captures.
  let
    root = createTempDir("slot-worker-", "")
    rom = root / "fixture.test"
    core = absolutePath("build/player-fixture.so")
  defer: removeDir(root)
  writeFile(rom, "V")
  let
    saves = root / "saves"
    worker = openCoreWorker(core, rom, saves)
    store = newStateStore(saves, rom, core, "", "")
  defer: worker.close()
  doAssert worker.stateExport and worker.stateImport
  doAssert worker.captureDirectory.len == 0
  worker.step(0)
  worker.prefetch(256)
  worker.saveSlot(1)
  let
    saved = readFile(store.slotPath(1))
    state = unwrapScreenstate(saved, $secureHashFile(rom), $secureHashFile(core))
    image = readImage(store.slotPath(1))
  doAssert state == worker.exportState()
  doAssert image.data[0] == rgbx(0, 255, 0, 255)
  worker.step(0)
  worker.step(0)
  doAssert worker.exportState() != state
  worker.importStateData(state, "slot1")
  doAssert worker.exportState() == state
  worker.step(0)
  doAssert worker.takeAudio().len == 0
  worker.close()

main()
