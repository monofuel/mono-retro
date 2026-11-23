import
  std/[monotimes, os, osproc, streams, times],
  ./bluetooth

type
  BluetoothWorker* = ref object
    state*: BtState
    fresh*: bool
    executable, statePath, previous: string
    process: Process
    checked: MonoTime
    request: uint64

proc newBluetoothWorker*(executable, statePath: string): BluetoothWorker =
  ## Keep worker state private to one launcher session.
  BluetoothWorker(executable: executable, statePath: statePath)

proc send*(worker: BluetoothWorker, command: BtCommand) =
  ## Send commands and pairing input through the owned child's standard input.
  if worker.process == nil:
    if not fileExists(worker.executable):
      worker.state.error = "Bluetooth settings are not installed"
      worker.fresh = true
      return
    if fileExists(worker.statePath): removeFile(worker.statePath)
    worker.previous = ""
    worker.fresh = false
    worker.process = startProcess(worker.executable,
      args = @["--state:" & worker.statePath], options = {poStdErrToStdOut})
  if not worker.process.running():
    raise newException(IOError, "Bluetooth worker is not running")
  var next = command
  inc worker.request
  next.request = worker.request
  worker.fresh = false
  worker.process.inputStream.write(next.commandJson() & "\n")
  worker.process.inputStream.flush()

proc poll*(worker: BluetoothWorker): bool =
  ## Consume atomic state snapshots without blocking the UI on radio operations.
  if worker.process == nil: return
  let now = getMonoTime()
  if (now - worker.checked).inMilliseconds < 150: return
  worker.checked = now
  if fileExists(worker.statePath):
    let text = readFile(worker.statePath)
    if text != worker.previous:
      worker.state = stateFromJson(text)
      worker.previous = text
      worker.fresh = worker.state.request == worker.request
      result = true
  if not worker.process.running():
    let code = worker.process.waitForExit()
    worker.process.close()
    worker.process = nil
    worker.state.available = false
    for device in worker.state.devices.mitems:
      device.audioReady = false
      device.gamepadReady = false
    worker.state.busy = false
    worker.state.prompt = BtPrompt()
    worker.state.error = "Bluetooth worker stopped (code " & $code & ")"
    worker.fresh = true
    result = true

proc close*(worker: BluetoothWorker) =
  ## Stop only our worker, leaving paired connections managed by BlueZ.
  if worker == nil: return
  if worker.process != nil:
    worker.process.inputStream.close()
    if worker.process.waitForExit(3000) == -1:
      worker.process.terminate()
      if worker.process.waitForExit(2000) == -1:
        worker.process.kill()
        discard worker.process.waitForExit()
    worker.process.close()
    worker.process = nil
  worker.fresh = false
  worker.previous = ""
  worker.state.prompt = BtPrompt()
  worker.state.busy = false
  if fileExists(worker.statePath): removeFile(worker.statePath)
