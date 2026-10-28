import
  std/[monotimes, os, osproc, times]

proc runTester*(path: string, arguments: seq[string],
    stopping: proc(): bool): int =
  ## Wait without retaining displays, forwarding service shutdown to the child.
  let process = startProcess(path, args = arguments, options = {poParentStreams})
  defer: process.close()
  var
    terminated = false
    deadline: MonoTime
  while process.running():
    if stopping() and not terminated:
      process.terminate()
      terminated = true
      deadline = getMonoTime() + initDuration(seconds = 5)
    if terminated and getMonoTime() >= deadline:
      process.kill()
      discard process.waitForExit()
      raise newException(IOError, "Child application did not stop after SIGTERM")
    sleep(8)
  process.waitForExit()
