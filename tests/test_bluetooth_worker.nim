import
  std/[monotimes, os, strutils, tempfiles, times],
  retro/[bluetooth, bluetoothworker]

proc fakeWorker(path: string) =
  ## Emulate only the documented stdin/snapshot protocol, without a system bus.
  for line in stdin.lines:
    let command = commandFromJson(line)
    if command.action == "die": quit(7)
    let state = BtState(request: command.request, available: true, powered: true,
      error: if command.action == "fail": "Fixture failure" else: "",
      devices: @[BtDevice(address: "01:23:45:67:89:AB", audioReady: true)])
    writeFile(path & ".tmp", state.stateJson())
    moveFile(path & ".tmp", path)

proc wait(worker: BluetoothWorker, predicate: proc(): bool) =
  ## Bound every protocol assertion while allowing the real polling interval.
  let deadline = getMonoTime() + initDuration(seconds = 3)
  while getMonoTime() < deadline:
    discard worker.poll()
    if predicate(): return
    sleep(10)
  raise newException(IOError, "Bluetooth worker fixture timed out")

proc main() =
  ## Confirm command acknowledgement, recovery, stopped-worker readiness and EOF cleanup.
  let
    root = createTempDir("mono-retro-bt-worker-", "")
    path = root / "state.json"
    worker = newBluetoothWorker(getAppFilename(), path)
  defer:
    worker.close()
    removeDir(root)
  worker.send(BtCommand(action: "fail"))
  worker.wait(proc(): bool = worker.fresh and worker.state.error == "Fixture failure")
  worker.send(BtCommand(action: "status"))
  doAssert not worker.fresh
  worker.wait(proc(): bool = worker.fresh and worker.state.request == 2)
  doAssert worker.state.error.len == 0
  worker.send(BtCommand(action: "status"))
  worker.wait(proc(): bool = worker.fresh and worker.state.request == 3)
  worker.send(BtCommand(action: "die"))
  worker.wait(proc(): bool = worker.state.error.contains("code 7"))
  doAssert not worker.state.available
  doAssert not worker.state.devices[0].audioReady
  worker.send(BtCommand(action: "status"))
  worker.wait(proc(): bool = worker.fresh and worker.state.request == 5)
  doAssert worker.state.available
  worker.close()
  doAssert not fileExists(path)
  let missing = newBluetoothWorker(root / "missing", path)
  missing.send(BtCommand(action: "status"))
  doAssert missing.fresh and missing.state.error.len > 0
  missing.close()

let arguments = commandLineParams()
if arguments.len == 1 and arguments[0].startsWith("--state:"):
  fakeWorker(arguments[0]["--state:".len .. ^1])
else:
  main()
