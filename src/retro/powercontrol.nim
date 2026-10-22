import
  std/osproc,
  ./[menu, systeminfo]

proc powerCommand*(action: MenuAction): string =
  ## Use the OS shutdown commands so OpenRC stops services and flushes filesystems.
  case action
  of RebootSystem: "reboot"
  of ShutdownSystem: "poweroff"
  else: raise newException(ValueError, "Not a power action")

proc powerBlockReason*(power: PowerStatus): string =
  ## Avoid the RG SP vendor kernel's known shutdown state while externally powered.
  if power.selected == "axp2202-battery" and power.external:
    "Unplug the RG SP charger before rebooting or shutting down."
  else: ""

proc requestPower*(action: MenuAction): Process =
  ## Keep the event loop responsive while the OS stops services, including this one.
  startProcess(powerCommand(action), options = {poUsePath, poParentStreams})

proc checkPowerRequest*(request: var Process, action: MenuAction) =
  ## Surface command failures without blocking the service's SIGTERM cleanup.
  if request == nil or request.running(): return
  let process = request
  request = nil
  defer: process.close()
  let code = process.waitForExit()
  if code != 0:
    raise newException(IOError, powerCommand(action) & " failed (" & $code & "); see launcher log")
