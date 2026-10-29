import
  paddy,
  ./[anbernic, input]

type
  GamepadMonitor* = object
    pads*: seq[Gamepad]
    seen: array[MaxGamepads, uint64]

proc physicalButton*(device, label: string): GamepadButton =
  ## Translate printed legends to Paddy's Xbox-style button positions.
  let anbernic = device in ["ANBERNIC-keys", "ANBERNIC-rk3568-keys", "retrogame_joypad"]
  case label
  of "A": (if anbernic: GamepadB else: GamepadA)
  of "B": (if anbernic: GamepadA else: GamepadB)
  of "X": (if anbernic: GamepadY else: GamepadX)
  of "Y": (if anbernic: GamepadX else: GamepadY)
  of "UP": GamepadUp
  of "DOWN": GamepadDown
  of "LEFT": GamepadLeft
  of "RIGHT": GamepadRight
  of "L": GamepadL1
  of "R": GamepadR1
  of "L2": GamepadL2
  of "R2": GamepadR2
  of "L3": GamepadL3
  of "R3": GamepadR3
  of "SELECT": GamepadSelect
  of "START": GamepadStart
  of "MENU": GamepadHome
  else: GamepadButtonCount

proc findPad*(monitor: GamepadMonitor, name: string): int =
  ## Match a profile's controller by name, independently of its slot.
  for index, pad in monitor.pads:
    if pad.name == name:
      return index
  -1

proc update*(monitor: var GamepadMonitor, pads: seq[Gamepad]) =
  ## Retain tested buttons while a controller remains connected.
  var retained: array[MaxGamepads, bool]
  for pad in pads:
    if pad.id notin 0 ..< MaxGamepads:
      raise newException(ValueError, "Paddy returned an invalid controller slot")
    for previous in monitor.pads:
      if previous.id == pad.id and previous.name == pad.name:
        retained[pad.id] = true
  for id in 0 ..< MaxGamepads:
    if not retained[id]: monitor.seen[id] = 0
  for pad in pads:
    monitor.seen[pad.id] = monitor.seen[pad.id] or pad.buttons or pad.pressed
  monitor.pads = pads

proc poll*(monitor: var GamepadMonitor) =
  ## Apply app-owned mappings to Paddy snapshots before testing logical controls.
  var pads = pollGamepads()
  for pad in pads.mitems:
    pad = pad.mapAnbernic()
  for previous in monitor.pads:
    var connected = false
    for pad in pads:
      if pad.id == previous.id and pad.name == previous.name: connected = true
    if not connected: echo "PADDY disconnected id=", previous.id, " name=", previous.name
  for pad in pads:
    let previous = monitor.findPad(pad.name)
    if previous < 0:
      echo "PADDY connected id=", pad.id, " name=", pad.name
    for button in GamepadA ..< GamepadButtonCount:
      if pad.buttonPressed(button): echo "APP press ", button
      if pad.buttonReleased(button): echo "APP release ", button
    for axis in GamepadLStickX ..< GamepadAxisCount:
      let value = pad.axis(axis)
      if (previous < 0 and value != 0) or
          (previous >= 0 and value != monitor.pads[previous].axis(axis)):
        echo "APP axis ", axis, "=", value
  monitor.update(pads)

proc usesPaddy*(binding: Binding): bool =
  ## Leave keyboard-only controls such as Back and volume on raw evdev.
  physicalButton(binding.device, binding.label) != GamepadButtonCount

proc active*(monitor: GamepadMonitor, binding: Binding): bool =
  ## Read a physical button's held state exclusively from Paddy.
  let
    index = monitor.findPad(binding.device)
    button = physicalButton(binding.device, binding.label)
  index >= 0 and button != GamepadButtonCount and monitor.pads[index].button(button)

proc observed*(monitor: GamepadMonitor, binding: Binding): bool =
  ## Check whether Paddy has observed this physical button.
  let
    index = monitor.findPad(binding.device)
    button = physicalButton(binding.device, binding.label)
  index >= 0 and button != GamepadButtonCount and
    (monitor.seen[monitor.pads[index].id] and (1'u64 shl button.int)) != 0

proc freshPress*(monitor: GamepadMonitor, binding: Binding): bool =
  ## Read Paddy's press edge rather than triggering actions from raw events.
  let
    index = monitor.findPad(binding.device)
    button = physicalButton(binding.device, binding.label)
  index >= 0 and button != GamepadButtonCount and monitor.pads[index].buttonPressed(button)

proc axisPosition*(monitor: GamepadMonitor, device: string, axis: GamepadAxis): float =
  ## Return Paddy's filtered coordinate for comparison with raw evdev.
  let index = monitor.findPad(device)
  if index >= 0: float(monitor.pads[index].axis(axis)) else: 0
