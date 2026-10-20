import
  std/[os, posix, strformat, strutils],
  ./[framebuffer, touch]

type
  InputEvent* {.importc: "struct input_event", header: "<linux/input.h>", bycopy.} = object
    time*: Timeval
    kind* {.importc: "type".}: uint16
    code*: uint16
    value*: int32
  AxisInfo {.importc: "struct input_absinfo", header: "<linux/input.h>", bycopy.} = object
    value, minimum, maximum, fuzz, flat, resolution: int32
  Control* = object
    kind*, code*: uint16
    value*, minimum*, maximum*, flat*: int32
    seen*, negativeSeen*, positiveSeen*: bool
  Binding* = object
    label*, device*: string
    kind*, code*: uint16
    value*: int32
  InputDevice* = ref object
    path*, name*: string
    fd*: cint
    controls*: seq[Control]
    touch*: TouchState
    dropped: bool

const
  EventSync* = 0'u16
  EventKey* = 1'u16
  EventAbsolute* = 3'u16
  SyncDropped = 3'u16
  KeyCapacity = 768
  AxisCapacity = 64
  KeyBytes = KeyCapacity div 8

proc getName(length: cint): culong {.importc: "EVIOCGNAME", header: "<linux/input.h>".}
proc getBits(kind, length: cint): culong {.importc: "EVIOCGBIT", header: "<linux/input.h>".}
proc getKeys(length: cint): culong {.importc: "EVIOCGKEY", header: "<linux/input.h>".}
proc getAxis(code: cint): culong {.importc: "EVIOCGABS", header: "<linux/input.h>".}
proc getSlots(length: cint): culong {.importc: "EVIOCGMTSLOTS", header: "<linux/input.h>".}

proc bitSet(bits: openArray[byte], code: int): bool =
  (bits[code div 8] and byte(1 shl (code mod 8))) != 0

proc syncState(device: InputDevice) =
  var keys: array[KeyBytes, byte]
  if deviceIoctl(device.fd, getKeys(KeyBytes), addr keys[0]) < 0:
    raiseOSError(osLastError(), "Reading button state")
  for control in device.controls.mitems:
    if control.kind == EventKey:
      control.value = int32(bitSet(keys, int(control.code)))
    else:
      var axis: AxisInfo
      if deviceIoctl(device.fd, getAxis(cint(control.code)), addr axis) < 0:
        raiseOSError(osLastError(), "Reading axis state")
      control.value = axis.value
      control.minimum = axis.minimum
      control.maximum = axis.maximum
      control.flat = axis.flat
  if device.touch.enabled:
    if device.touch.multitouch:
      for control in device.controls:
        if control.kind == EventAbsolute and control.code == SlotCode:
          device.touch.slot = int(control.value) - device.touch.slotMinimum
      for code in [TrackingCode, PositionXCode, PositionYCode]:
        var values = newSeq[int32](device.touch.pending.len + 1)
        values[0] = int32(code)
        if deviceIoctl(device.fd, getSlots(cint(values.len * sizeof(int32))), addr values[0]) < 0:
          raiseOSError(osLastError(), "Resynchronizing touch slots")
        for index in 0 ..< device.touch.pending.len:
          case code
          of TrackingCode:
            device.touch.pending[index].id = values[index + 1]
            device.touch.pending[index].active = values[index + 1] >= 0
          of PositionXCode: device.touch.pending[index].x = values[index + 1]
          of PositionYCode: device.touch.pending[index].y = values[index + 1]
          else: discard
    else:
      for control in device.controls:
        if control.kind == EventAbsolute and control.code in [0'u16, 1'u16]:
          device.touch.apply(control.kind, control.code, control.value)
        elif control.kind == EventKey and control.code == TouchCode:
          device.touch.apply(control.kind, control.code, control.value)
    device.touch.commit()

proc configureTouch*(device: InputDevice) =
  ## Configure protocol-B or legacy touch from the device's reported capabilities.
  var
    slots = 0
    hasTouch = false
    hasX = false
    hasY = false
  for control in device.controls:
    if control.kind == EventAbsolute and control.code == SlotCode:
      slots = int(control.maximum - control.minimum + 1)
      device.touch.slotMinimum = int(control.minimum)
    elif control.kind == EventKey and control.code == TouchCode:
      hasTouch = true
  device.touch.multitouch = slots > 0
  for control in device.controls:
    if control.kind == EventAbsolute:
      if control.code == (if slots > 0: PositionXCode else: 0'u16):
        device.touch.minimumX = control.minimum
        device.touch.maximumX = control.maximum
        hasX = control.maximum > control.minimum
      elif control.code == (if slots > 0: PositionYCode else: 1'u16):
        device.touch.minimumY = control.minimum
        device.touch.maximumY = control.maximum
        hasY = control.maximum > control.minimum
  device.touch.enabled = hasX and hasY and (slots > 0 or hasTouch)
  if device.touch.enabled:
    if slots > MaximumTouchSlots:
      raise newException(IOError, "Touch device exceeds supported slot count")
    device.touch.pending = newSeq[TouchContact](max(1, slots))
    device.touch.clear()

proc openInput*(path: string): InputDevice =
  result = InputDevice(path: path, fd: posix.open(path.cstring, O_RDONLY or O_NONBLOCK or O_CLOEXEC))
  if result.fd < 0:
    raiseOSError(osLastError(), path)
  try:
    var
      name: array[256, char]
      keys: array[KeyBytes, byte]
      axes: array[AxisCapacity div 8, byte]
    if deviceIoctl(result.fd, getName(cint(name.len)), addr name[0]) < 0:
      raiseOSError(osLastError(), "Reading input name")
    result.name = $cast[cstring](addr name[0])
    if deviceIoctl(result.fd, getBits(EventKey.cint, KeyBytes), addr keys[0]) < 0 or
        deviceIoctl(result.fd, getBits(EventAbsolute.cint, cint(axes.len)), addr axes[0]) < 0:
      raiseOSError(osLastError(), "Reading input capabilities")
    for code in 0 ..< KeyCapacity:
      if bitSet(keys, code):
        result.controls.add Control(kind: EventKey, code: uint16(code), minimum: 0, maximum: 1)
    for code in 0 ..< AxisCapacity:
      if bitSet(axes, code):
        result.controls.add Control(kind: EventAbsolute, code: uint16(code))
    result.syncState()
    result.configureTouch()
    if result.touch.enabled:
      result.syncState()
  except:
    discard posix.close(result.fd)
    raise

proc axisDirection*(control: Control): int32 =
  if control.code in 16'u16..23'u16:
    if control.value < 0: return -1
    if control.value > 0: return 1
    return 0
  let
    center = (float(control.minimum) + float(control.maximum)) / 2
    threshold = max(0.25, (float(control.maximum) - float(control.minimum)) / 4)
  if float(control.value) < center - threshold: -1
  elif float(control.value) > center + threshold: 1
  else: 0

proc applyEvent*(controls: var seq[Control], event: InputEvent) =
  for control in controls.mitems:
    if control.kind == event.kind and control.code == event.code:
      control.value = event.value
      if event.kind != EventKey or event.value != 0:
        control.seen = true
      if event.kind == EventAbsolute:
        let direction = control.axisDirection()
        if direction < 0: control.negativeSeen = true
        if direction > 0: control.positiveSeen = true
      return

proc axisPosition*(control: Control): float =
  ## Scale raw analog values linearly without a deadzone or smoothing.
  if control.maximum <= control.minimum:
    raise newException(ValueError, "Axis coordinate range is invalid")
  let
    center = (float(control.minimum) + float(control.maximum)) / 2
    halfRange = (float(control.maximum) - float(control.minimum)) / 2
    offset = float(control.value) - center
  max(-1.0, min(1.0, offset / halfRange))

proc axis*(device: InputDevice, code: uint16): Control =
  ## Find a configured absolute axis and reject a mismatched profile.
  for control in device.controls:
    if control.kind == EventAbsolute and control.code == code:
      return control
  raise newException(ValueError, "Missing axis " & $code & " on " & device.name)

proc active*(binding: Binding, devices: seq[InputDevice]): bool =
  for device in devices:
    if device.name == binding.device:
      for control in device.controls:
        if control.kind == binding.kind and control.code == binding.code:
          return if control.kind == EventKey: control.value != 0
            else: control.axisDirection() == binding.value

proc observed*(binding: Binding, devices: seq[InputDevice]): bool =
  for device in devices:
    if device.name == binding.device:
      for control in device.controls:
        if control.kind == binding.kind and control.code == binding.code:
          return if control.kind == EventKey: control.seen
            elif binding.value < 0: control.negativeSeen
            else: control.positiveSeen

proc tonePress*(event: InputEvent, toneKey: uint16, exitHeld: bool): bool =
  event.kind == EventKey and event.code == toneKey and event.value == 1 and not exitHeld

proc readEvents*(device: InputDevice): seq[InputEvent] =
  while true:
    var event: InputEvent
    let count = posix.read(device.fd, addr event, sizeof(event))
    if count < 0:
      let error = osLastError()
      if error == OSErrorCode(EAGAIN):
        break
      if error == OSErrorCode(EINTR):
        continue
      raiseOSError(error, device.path)
    if count != sizeof(event):
      raise newException(IOError, "Incomplete input event or disconnected device: " & device.path)
    if event.kind == EventSync and event.code == SyncDropped:
      device.dropped = true
      device.touch.clear()
    elif device.dropped:
      if event.kind == EventSync and event.code == 0:
        device.syncState()
        device.dropped = false
    elif event.kind in [EventKey, EventAbsolute]:
      device.controls.applyEvent(event)
      device.touch.apply(event.kind, event.code, event.value)
      result.add event
    elif event.kind == EventSync and event.code == 0:
      device.touch.commit()
      result.add event

proc inputPaths*(names: seq[string]): seq[string] =
  for path in walkFiles("/sys/class/input/event*/device/name"):
    let name = readFile(path).strip()
    if name in names or (names.len == 0 and
        ("keys" in name.toLowerAscii() or "gamepad" in name.toLowerAscii()) and
        "power" notin name.toLowerAscii()):
      let event = path.parentDir().parentDir().extractFilename()
      result.add "/dev/input/" & event

proc label*(control: Control): string =
  if control.kind == EventAbsolute:
    return "AX" & $control.code & ":" & $control.value
  case control.code
  of 28: "ENTER"
  of 103: "UP"
  of 105: "LEFT"
  of 106: "RIGHT"
  of 108: "DOWN"
  of 304: "SOUTH"
  of 305: "EAST"
  of 307: "NORTH"
  of 308: "WEST"
  of 310: "L"
  of 311: "R"
  of 312: "L2"
  of 313: "R2"
  of 314: "SELECT"
  of 315: "START"
  of 316: "MODE"
  else: "K" & $control.code

proc describe*(device: InputDevice): string =
  let count = device.controls.len
  &"{device.path}: {device.name} ({count} controls)"

proc close*(device: InputDevice) =
  if device.fd >= 0:
    let code = posix.close(device.fd)
    device.fd = -1
    if code < 0:
      raiseOSError(osLastError())
