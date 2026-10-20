import
  std/[os, posix, strformat, strutils],
  ./framebuffer

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
    value*, minimum*, maximum*: int32
    seen*, negativeSeen*, positiveSeen*: bool
  Binding* = object
    label*, device*: string
    kind*, code*: uint16
    value*: int32
  InputDevice* = ref object
    path*, name*: string
    fd*: cint
    controls*: seq[Control]
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
  except:
    discard posix.close(result.fd)
    raise

proc applyEvent*(controls: var seq[Control], event: InputEvent) =
  for control in controls.mitems:
    if control.kind == event.kind and control.code == event.code:
      control.value = event.value
      if event.kind != EventKey or event.value != 0:
        control.seen = true
      if event.kind == EventAbsolute:
        let
          center = (float(control.minimum) + float(control.maximum)) / 2
          threshold = max(0.25, (float(control.maximum) - float(control.minimum)) / 4)
        if float(control.value) < center - threshold: control.negativeSeen = true
        if float(control.value) > center + threshold: control.positiveSeen = true
      return

proc axisDirection*(control: Control): int32 =
  let
    center = (float(control.minimum) + float(control.maximum)) / 2
    threshold = max(0.25, (float(control.maximum) - float(control.minimum)) / 4)
  if float(control.value) < center - threshold: -1
  elif float(control.value) > center + threshold: 1
  else: 0

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
    elif device.dropped:
      if event.kind == EventSync and event.code == 0:
        device.syncState()
        device.dropped = false
    elif event.kind in [EventKey, EventAbsolute]:
      device.controls.applyEvent(event)
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
