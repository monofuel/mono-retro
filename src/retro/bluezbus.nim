## A bounded BlueZ session using the system bus and an application-owned Agent1.
## C structures are imported from the libdbus headers, never re-created in Nim.

import
  std/[algorithm, json, monotimes, os, sequtils, strutils, tables, times],
  ./[bluetooth]

type
  BusConnection* {.importc: "DBusConnection", header: "<dbus/dbus.h>", incompleteStruct.} = object
  BusMessage* {.importc: "DBusMessage", header: "<dbus/dbus.h>", incompleteStruct.} = object
  BusPending* {.importc: "DBusPendingCall", header: "<dbus/dbus.h>", incompleteStruct.} = object
  BusIter {.importc: "DBusMessageIter", header: "<dbus/dbus.h>", bycopy.} = object
  BusError {.importc: "DBusError", header: "<dbus/dbus.h>", bycopy.} = object
  BusResult* {.importc: "DBusHandlerResult", header: "<dbus/dbus.h>".} = enum
    BusHandled = 0, BusNotHandled = 1, BusNeedMemory = 2
  BusFilter* = proc(connection: ptr BusConnection, message: ptr BusMessage,
    data: pointer): BusResult {.cdecl.}
  BusArg* = object
    signature*: string
    value*: JsonNode
  BtLimits* = object
    refreshMs*, requestMs*, operationMs*, pairMs*, promptMs*, scanMs*: int
  BusRequest = object
    pending: ptr BusPending
    tag: string
    deadline: MonoTime
  BtSession* = ref object
    state*: BtState
    connection*: ptr BusConnection
    limits: BtLimits
    adapter, scanAdapter, bluezOwner, operation, devicePath, deviceAddress: string
    objects, pcms: JsonNode
    paths: Table[string, string]
    requests: seq[BusRequest]
    agentRegistered, scanOwned, closed, modernPcms: bool
    agentRequest: ptr BusMessage
    promptDeadline, scanDeadline, nextRefresh: MonoTime
    inputRoot: string

const
  AgentPath* = "/org/monoretro/BluetoothAgent"
  BluezService* = "org.bluez"
  AdapterInterface* = "org.bluez.Adapter1"
  DeviceInterface* = "org.bluez.Device1"
  AgentInterface* = "org.bluez.Agent1"
  AgentManagerInterface* = "org.bluez.AgentManager1"
  ObjectManagerInterface* = "org.freedesktop.DBus.ObjectManager"
  PropertiesInterface* = "org.freedesktop.DBus.Properties"
  DefaultBtLimits* = BtLimits(refreshMs: 1000, requestMs: 2500,
    operationMs: 20000, pairMs: 60000, promptMs: 45000, scanMs: 20000)
  MaxDispatchMs = 25
  MaxWireDepth = 32
  HidUuid = "00001124-0000-1000-8000-00805f9b34fb"
  HogUuid = "00001812-0000-1000-8000-00805f9b34fb"

{.push cdecl, header: "<dbus/dbus.h>".}
proc busGetPrivate(kind: cint, error: ptr BusError): ptr BusConnection {.importc: "dbus_bus_get_private".}
proc connectionOpenPrivate(address: cstring, error: ptr BusError): ptr BusConnection {.importc: "dbus_connection_open_private".}
proc busRegister(connection: ptr BusConnection, error: ptr BusError): cuint {.importc: "dbus_bus_register".}
proc busRequestName*(connection: ptr BusConnection, name: cstring, flags: cuint,
  error: pointer): cint {.importc: "dbus_bus_request_name".}
proc busUniqueName*(connection: ptr BusConnection): cstring {.importc: "dbus_bus_get_unique_name".}
proc connectionClose*(connection: ptr BusConnection) {.importc: "dbus_connection_close".}
proc connectionUnref*(connection: ptr BusConnection) {.importc: "dbus_connection_unref".}
proc connectionConnected(connection: ptr BusConnection): cuint {.importc: "dbus_connection_get_is_connected".}
proc setExitOnDisconnect(connection: ptr BusConnection, enabled: cuint) {.importc: "dbus_connection_set_exit_on_disconnect".}
proc addFilter*(connection: ptr BusConnection, callback: BusFilter, data: pointer,
  freeData: pointer): cuint {.importc: "dbus_connection_add_filter".}
proc removeFilter(connection: ptr BusConnection, callback: BusFilter, data: pointer) {.importc: "dbus_connection_remove_filter".}
proc readWriteDispatch*(connection: ptr BusConnection, timeout: cint): cuint {.importc: "dbus_connection_read_write_dispatch".}
proc messageNewCall*(destination, path, iface, member: cstring): ptr BusMessage {.importc: "dbus_message_new_method_call".}
proc messageNewReturn*(call: ptr BusMessage): ptr BusMessage {.importc: "dbus_message_new_method_return".}
proc messageNewError*(call: ptr BusMessage, name, text: cstring): ptr BusMessage {.importc: "dbus_message_new_error".}
proc messageRef*(message: ptr BusMessage): ptr BusMessage {.importc: "dbus_message_ref".}
proc messageUnref*(message: ptr BusMessage) {.importc: "dbus_message_unref".}
proc messageType*(message: ptr BusMessage): cint {.importc: "dbus_message_get_type".}
proc messagePath*(message: ptr BusMessage): cstring {.importc: "dbus_message_get_path".}
proc messageMember*(message: ptr BusMessage): cstring {.importc: "dbus_message_get_member".}
proc messageInterface*(message: ptr BusMessage): cstring {.importc: "dbus_message_get_interface".}
proc messageSender*(message: ptr BusMessage): cstring {.importc: "dbus_message_get_sender".}
proc messageErrorName*(message: ptr BusMessage): cstring {.importc: "dbus_message_get_error_name".}
proc connectionSend*(connection: ptr BusConnection, message: ptr BusMessage,
  serial: ptr uint32): cuint {.importc: "dbus_connection_send".}
proc sendWithReply*(connection: ptr BusConnection, message: ptr BusMessage,
  pending: ptr ptr BusPending, timeout: cint): cuint {.importc: "dbus_connection_send_with_reply".}
proc pendingCompleted*(pending: ptr BusPending): cuint {.importc: "dbus_pending_call_get_completed".}
proc pendingStealReply*(pending: ptr BusPending): ptr BusMessage {.importc: "dbus_pending_call_steal_reply".}
proc pendingCancel*(pending: ptr BusPending) {.importc: "dbus_pending_call_cancel".}
proc pendingUnref*(pending: ptr BusPending) {.importc: "dbus_pending_call_unref".}
proc iterInit(message: ptr BusMessage, iter: ptr BusIter): cuint {.importc: "dbus_message_iter_init".}
proc iterInitAppend(message: ptr BusMessage, iter: ptr BusIter) {.importc: "dbus_message_iter_init_append".}
proc iterType(iter: ptr BusIter): cint {.importc: "dbus_message_iter_get_arg_type".}
proc iterElementType(iter: ptr BusIter): cint {.importc: "dbus_message_iter_get_element_type".}
proc iterNext(iter: ptr BusIter): cuint {.importc: "dbus_message_iter_next".}
proc iterRecurse(iter, child: ptr BusIter) {.importc: "dbus_message_iter_recurse".}
proc iterGetBasic(iter: ptr BusIter, value: pointer) {.importc: "dbus_message_iter_get_basic".}
proc iterAppendBasic(iter: ptr BusIter, kind: cint, value: pointer): cuint {.importc: "dbus_message_iter_append_basic".}
proc iterOpen(iter: ptr BusIter, kind: cint, signature: cstring,
  child: ptr BusIter): cuint {.importc: "dbus_message_iter_open_container".}
proc iterClose(iter, child: ptr BusIter): cuint {.importc: "dbus_message_iter_close_container".}
{.pop.}

proc afterMs(milliseconds: int): MonoTime =
  ## Return a monotonic deadline unaffected by clock corrections.
  getMonoTime() + initDuration(milliseconds = milliseconds)

proc checkMemory(ok: cuint) =
  ## Convert libdbus allocation failures into an explicit error.
  if ok == 0: raise newException(IOError, "D-Bus allocation failed")

proc openBus*(address = ""): ptr BusConnection =
  ## Open a private system-bus connection, or an explicitly supplied test bus.
  if address.len == 0:
    result = busGetPrivate(1, nil)
  else:
    result = connectionOpenPrivate(address.cstring, nil)
    if result != nil and busRegister(result, nil) == 0:
      connectionClose(result)
      connectionUnref(result)
      result = nil
  if result == nil: raise newException(IOError, "Bluetooth system bus is unavailable")
  setExitOnDisconnect(result, 0)

proc readValue(iter: var BusIter, depth = 0): JsonNode =
  ## Decode typed D-Bus values while retaining nested dictionary structure.
  if depth > MaxWireDepth: raise newException(ValueError, "D-Bus value is too deeply nested")
  let kind = iterType(addr iter)
  case kind
  of ord('s'), ord('o'), ord('g'):
    var value: cstring
    iterGetBasic(addr iter, addr value)
    result = %($value)
  of ord('b'), ord('u'):
    var value: uint32
    iterGetBasic(addr iter, addr value)
    result = if kind == ord('b'): %(value != 0) else: %value
  of ord('y'):
    var value: uint8
    iterGetBasic(addr iter, addr value)
    result = %value
  of ord('q'):
    var value: uint16
    iterGetBasic(addr iter, addr value)
    result = %value
  of ord('n'):
    var value: int16
    iterGetBasic(addr iter, addr value)
    result = %value
  of ord('i'), ord('h'):
    var value: int32
    iterGetBasic(addr iter, addr value)
    result = %value
  of ord('x'):
    var value: int64
    iterGetBasic(addr iter, addr value)
    result = %value
  of ord('t'):
    var value: uint64
    iterGetBasic(addr iter, addr value)
    result = %value
  of ord('d'):
    var value: cdouble
    iterGetBasic(addr iter, addr value)
    result = %value
  of ord('v'):
    var child: BusIter
    iterRecurse(addr iter, addr child)
    result = readValue(child, depth + 1)
  of ord('a'), ord('r'), ord('e'):
    var child: BusIter
    iterRecurse(addr iter, addr child)
    result = newJArray()
    if kind == ord('a') and iterElementType(addr iter) == ord('e'):
      result = newJObject()
      while iterType(addr child) != 0:
        var entry: BusIter
        iterRecurse(addr child, addr entry)
        let key = readValue(entry, depth + 1).getStr()
        if iterNext(addr entry) == 0: raise newException(ValueError, "Invalid D-Bus dictionary")
        result[key] = readValue(entry, depth + 1)
        discard iterNext(addr child)
    else:
      while iterType(addr child) != 0:
        result.add readValue(child, depth + 1)
        discard iterNext(addr child)
  else:
    raise newException(ValueError, "Unsupported D-Bus value type")

proc messageArgs*(message: ptr BusMessage): seq[JsonNode] =
  ## Decode a complete message body without stringifying secret-bearing calls.
  var iter: BusIter
  if iterInit(message, addr iter) == 0: return
  while iterType(addr iter) != 0:
    result.add readValue(iter)
    discard iterNext(addr iter)

proc appendValue(iter: var BusIter, signature: string, value: JsonNode) =
  ## Append explicit wire types; variant values carry a signature and value.
  let kind = signature[0]
  case kind
  of 's', 'o', 'g':
    var text = value.getStr().cstring
    checkMemory(iterAppendBasic(addr iter, ord(kind).cint, addr text))
  of 'b', 'u':
    var number = if kind == 'b': uint32(value.getBool()) else: uint32(value.getBiggestInt())
    checkMemory(iterAppendBasic(addr iter, ord(kind).cint, addr number))
  of 'y':
    var number = uint8(value.getInt())
    checkMemory(iterAppendBasic(addr iter, ord(kind).cint, addr number))
  of 'q':
    var number = uint16(value.getInt())
    checkMemory(iterAppendBasic(addr iter, ord(kind).cint, addr number))
  of 'n':
    var number = int16(value.getInt())
    checkMemory(iterAppendBasic(addr iter, ord(kind).cint, addr number))
  of 'i':
    var number = int32(value.getInt())
    checkMemory(iterAppendBasic(addr iter, ord(kind).cint, addr number))
  of 'v':
    var child: BusIter
    let inner = value["signature"].getStr()
    checkMemory(iterOpen(addr iter, ord('v').cint, inner.cstring, addr child))
    appendValue(child, inner, value["value"])
    checkMemory(iterClose(addr iter, addr child))
  of 'a':
    var child: BusIter
    let element = signature[1 .. ^1]
    checkMemory(iterOpen(addr iter, ord('a').cint, element.cstring, addr child))
    if element[0] == '{':
      let
        keySignature = element[1 .. 1]
        valueSignature = element[2 .. ^2]
      for key, item in value:
        var entry: BusIter
        checkMemory(iterOpen(addr child, ord('e').cint, nil, addr entry))
        appendValue(entry, keySignature, %key)
        appendValue(entry, valueSignature, item)
        checkMemory(iterClose(addr child, addr entry))
    else:
      for item in value: appendValue(child, element, item)
    checkMemory(iterClose(addr iter, addr child))
  else: raise newException(ValueError, "Unsupported outgoing D-Bus type")

proc busArg*(signature: string, value: JsonNode): BusArg =
  ## Describe a typed method argument, including object paths and variants.
  BusArg(signature: signature, value: value)

proc variant*(signature: string, value: JsonNode): JsonNode =
  ## Describe one explicit D-Bus variant for properties and test fixtures.
  %*{"signature": signature, "value": value}

proc appendArgs*(message: ptr BusMessage, args: openArray[BusArg]) =
  ## Append a typed argument list using the header-defined iterator structure.
  var iter: BusIter
  iterInitAppend(message, addr iter)
  for argument in args: appendValue(iter, argument.signature, argument.value)

proc sendReply*(connection: ptr BusConnection, call: ptr BusMessage,
    args: openArray[BusArg] = []) =
  ## Send a method return without logging its potentially private body.
  let reply = messageNewReturn(call)
  if reply == nil: raise newException(IOError, "D-Bus allocation failed")
  defer: messageUnref(reply)
  appendArgs(reply, args)
  checkMemory(connectionSend(connection, reply, nil))

proc sendError*(connection: ptr BusConnection, call: ptr BusMessage,
    name = "org.bluez.Error.Rejected", text = "Bluetooth request rejected") =
  ## Send a generic error, excluding PINs and daemon-provided message text.
  let reply = messageNewError(call, name.cstring, text.cstring)
  if reply == nil: raise newException(IOError, "D-Bus allocation failed")
  defer: messageUnref(reply)
  checkMemory(connectionSend(connection, reply, nil))

proc queue(session: BtSession, tag, path, iface, member: string,
    args: openArray[BusArg] = [], destination = BluezService, timeout = 0) =
  ## Queue an asynchronous call so Agent1 and stdin continue to be dispatched.
  let
    message = messageNewCall(destination.cstring, path.cstring, iface.cstring, member.cstring)
    duration = if timeout > 0: timeout else: session.limits.requestMs
  if message == nil: raise newException(IOError, "D-Bus allocation failed")
  defer: messageUnref(message)
  appendArgs(message, args)
  var pending: ptr BusPending
  checkMemory(sendWithReply(session.connection, message, addr pending, duration.cint))
  if pending == nil: raise newException(IOError, "D-Bus connection is unavailable")
  session.requests.add BusRequest(pending: pending, tag: tag, deadline: afterMs(duration))

proc hasRequest(session: BtSession, tag: string): bool =
  ## Prevent overlapping background snapshots and cleanup requests.
  for request in session.requests:
    if request.tag == tag: return true

proc clearPrompt(session: BtSession, reject = false) =
  ## Release the sole pending agent reply and clear its private display state.
  if session.agentRequest != nil:
    if reject: sendError(session.connection, session.agentRequest, "org.bluez.Error.Canceled")
    messageUnref(session.agentRequest)
    session.agentRequest = nil
  session.state.prompt = BtPrompt()

proc endOperation(session: BtSession, error = "") =
  ## Finish the foreground operation without persisting entered credentials.
  session.clearPrompt(reject = true)
  session.state.busy = false
  session.state.error = error
  session.operation = ""
  session.devicePath = ""
  session.deviceAddress = ""
  session.nextRefresh = getMonoTime()

proc stopScan(session: BtSession) =
  ## Stop only discovery acquired by this private connection.
  if session.scanOwned and not session.hasRequest("stopScan"):
    session.queue("stopScan", session.scanAdapter, AdapterInterface, "StopDiscovery")

proc cancel*(session: BtSession) =
  ## Cancel this session's pending pair/connect operation and owned discovery.
  if session == nil or session.connection == nil: return
  if session.operation == "pair":
    session.queue("cancelPair", session.devicePath, DeviceInterface, "CancelPairing")
  elif session.operation == "connect":
    session.queue("cancelConnect", session.devicePath, DeviceInterface, "Disconnect")
  for index in countdown(session.requests.high, 0):
    if session.requests[index].tag == "operation":
      pendingCancel(session.requests[index].pending)
      pendingUnref(session.requests[index].pending)
      session.requests.delete(index)
  session.endOperation()
  session.state.message = "Cancelled"
  session.stopScan()

proc hidReady(address: string, root: string): bool =
  ## Require an OS input device with a matching Bluetooth identity and gamepad keys.
  if not dirExists(root): return false
  for kind, path in walkDir(root):
    if kind notin {pcDir, pcLinkToDir} or not path.extractFilename().startsWith("event"): continue
    let
      identityPath = path / "device/uniq"
      ueventPath = path / "device/uevent"
    if not fileExists(identityPath) or not fileExists(ueventPath): continue
    if readFile(identityPath).strip().toUpperAscii() != address: continue
    if not readFile(ueventPath).splitLines().anyIt(it.startsWith("PRODUCT=5/")): continue
    # The input key bitmap uses hexadecimal words, ordered high to low.
    let keysPath = path / "device/capabilities/key"
    if not fileExists(keysPath): continue
    let words = readFile(keysPath).strip().splitWhitespace()
    const GamepadButton = 0x130
    let
      wordBits = sizeof(clong) * 8
      wordIndex = GamepadButton div wordBits
      bitIndex = GamepadButton mod wordBits
    if words.len > wordIndex:
      let word = cast[uint](parseHexInt(words[words.high - wordIndex]))
      if (word and (1'u shl bitIndex)) != 0: return true

proc rebuildState(session: BtSession) =
  ## Derive readiness from BlueALSA playback PCMs and actual OS gamepad evidence.
  session.paths.clear()
  session.adapter = ""
  session.state.available = false
  session.state.powered = false
  session.state.discovering = false
  session.state.devices.setLen(0)
  if session.objects == nil or session.objects.kind != JObject: return
  var objectPaths: seq[string]
  for path in session.objects.keys: objectPaths.add path
  objectPaths.sort()
  for path in objectPaths:
    let interfaces = session.objects[path]
    if interfaces.hasKey(AdapterInterface):
      session.adapter = path
      let properties = interfaces[AdapterInterface]
      session.state.available = true
      session.state.powered = properties{"Powered"}.getBool()
      session.state.discovering = properties{"Discovering"}.getBool()
      break
  for path in objectPaths:
    let interfaces = session.objects[path]
    if not interfaces.hasKey(DeviceInterface): continue
    let properties = interfaces[DeviceInterface]
    if properties{"Adapter"}.getStr() != session.adapter: continue
    let address = properties{"Address"}.getStr().toUpperAscii()
    if not validateAddress(address): continue
    var device = BtDevice(address: address, name: properties{"Alias"}.getStr(),
      icon: properties{"Icon"}.getStr(), paired: properties{"Paired"}.getBool(),
      trusted: properties{"Trusted"}.getBool(), connected: properties{"Connected"}.getBool(),
      batteryPercent: -1)
    if device.name.len == 0: device.name = properties{"Name"}.getStr(address)
    if interfaces.hasKey("org.bluez.Battery1"):
      let battery = interfaces["org.bluez.Battery1"]{"Percentage"}.getInt(-1)
      if battery in 0 .. 100: device.batteryPercent = battery
    if device.connected and session.pcms != nil and session.pcms.kind == JObject:
      for pcmPath, pcm in session.pcms:
        if pcm{"Device"}.getStr() == path and pcm{"Transport"}.getStr() == "A2DP-source" and
            pcm{"Mode"}.getStr() == "sink" and pcm{"Codec"}.getStr() == "SBC" and
            pcm{"Channels"}.getInt() > 0 and
            max(pcm{"Sampling"}.getInt(), pcm{"Rate"}.getInt()) > 0:
          device.audioReady = true
    let uuids = properties{"UUIDs"}
    if device.connected and properties{"ServicesResolved"}.getBool() and uuids != nil:
      for uuid in uuids:
        if uuid.getStr().toLowerAscii() in [HidUuid, HogUuid]:
          device.gamepadReady = hidReady(address, session.inputRoot)
    session.paths[address] = path
    session.state.devices.add device
  session.state.devices.sort(proc(left, right: BtDevice): int = cmp(left.address, right.address))

proc agentFilter(connection: ptr BusConnection, message: ptr BusMessage,
    data: pointer): BusResult {.cdecl.} =
  ## Handle only our own Agent1 requests from the verified current BlueZ owner.
  if messageType(message) != 1 or $messagePath(message) != AgentPath: return BusNotHandled
  let session = cast[BtSession](data)
  try:
    if $messageInterface(message) != AgentInterface:
      sendError(connection, message, "org.freedesktop.DBus.Error.UnknownMethod")
      return BusHandled
    if session.bluezOwner.len == 0 or $messageSender(message) != session.bluezOwner:
      sendError(connection, message)
      return BusHandled
    let member = $messageMember(message)
    if member in ["Cancel", "Release"]:
      session.clearPrompt(reject = true)
      if member == "Release": session.agentRegistered = false
      sendReply(connection, message)
      return BusHandled
    let args = messageArgs(message)
    if session.operation != "pair" or args.len == 0 or args[0].getStr() != session.devicePath:
      sendError(connection, message)
      return BusHandled
    if session.agentRequest != nil:
      sendError(connection, message, "org.bluez.Error.InProgress")
      return BusHandled
    var prompt = BtPrompt(address: session.deviceAddress)
    case member
    of "RequestPinCode":
      prompt.kind = PinPrompt
      prompt.text = "Enter the device PIN"
    of "RequestPasskey":
      prompt.kind = PasskeyPrompt
      prompt.text = "Enter the six-digit passkey"
    of "RequestConfirmation":
      if args.len != 2 or args[1].getInt(-1) notin 0 .. 999999:
        sendError(connection, message)
        return BusHandled
      prompt.kind = ConfirmPrompt
      prompt.passkey = uint32(args[1].getInt())
      prompt.code = align($prompt.passkey, 6, '0')
      prompt.text = "Confirm the matching passkey"
    of "RequestAuthorization":
      prompt.kind = ConfirmPrompt
      prompt.text = "Allow pairing with this device?"
    of "AuthorizeService":
      if args.len != 2 or args[1].getStr().toLowerAscii() notin [HidUuid, HogUuid,
          "0000110b-0000-1000-8000-00805f9b34fb"]:
        sendError(connection, message)
        return BusHandled
      prompt.kind = ConfirmPrompt
      prompt.text = "Allow this device service?"
    of "DisplayPasskey":
      if args.len != 3 or args[1].getInt(-1) notin 0 .. 999999 or args[2].getInt(-1) notin 0 .. 6:
        sendError(connection, message)
        return BusHandled
      prompt.kind = DisplayPrompt
      prompt.passkey = uint32(args[1].getInt())
      prompt.code = align($prompt.passkey, 6, '0')
      prompt.text = "Type this passkey on the device (" & $args[2].getInt() & "/6 entered)"
    of "DisplayPinCode":
      if args.len != 2 or args[1].getStr().len notin 1 .. 16:
        sendError(connection, message)
        return BusHandled
      prompt.kind = DisplayPrompt
      prompt.code = args[1].getStr()
      prompt.text = "Type this PIN on the device"
    else:
      sendError(connection, message, "org.freedesktop.DBus.Error.UnknownMethod")
      return BusHandled
    session.state.prompt = prompt
    session.promptDeadline = afterMs(session.limits.promptMs)
    if prompt.kind == DisplayPrompt: sendReply(connection, message)
    else: session.agentRequest = messageRef(message)
    return BusHandled
  except CatchableError:
    # Exceptions cannot cross the C callback boundary; report a secret-free error.
    session.state.error = "Invalid Bluetooth agent request"
    return BusNeedMemory

proc refresh(session: BtSession) =
  ## Poll authoritative daemon snapshots while allowing foreground calls to wait.
  if not session.hasRequest("objects"):
    session.queue("objects", "/", ObjectManagerInterface, "GetManagedObjects")
  if not session.hasRequest("pcms"):
    if session.modernPcms:
      session.queue("pcms", "/org/bluealsa", ObjectManagerInterface,
        "GetManagedObjects", destination = "org.bluealsa")
    else:
      session.queue("pcms", "/org/bluealsa", "org.bluealsa.Manager1",
        "GetPCMs", destination = "org.bluealsa")
  session.nextRefresh = afterMs(session.limits.refreshMs)

proc openBtSession*(address = "", limits = DefaultBtLimits,
    inputRoot = "/sys/class/input"): BtSession =
  ## Open a private bus session without taking the default agent or changing radio state.
  result = BtSession(limits: limits, inputRoot: inputRoot,
    objects: newJObject(), pcms: newJObject())
  result.connection = openBus(address)
  checkMemory(addFilter(result.connection, agentFilter, cast[pointer](result), nil))
  result.state.message = "Checking Bluetooth"
  result.refresh()

proc replyPrompt(session: BtSession, value: string) =
  ## Validate and answer only the currently pending request from the owned pairing.
  if session.agentRequest == nil:
    raise newException(ValueError, "No Bluetooth answer is pending")
  case session.state.prompt.kind
  of PinPrompt:
    if value.len notin 1 .. 16 or not value.allCharsInSet({' '..'~'}):
      raise newException(ValueError, "PIN must contain 1-16 printable characters")
    sendReply(session.connection, session.agentRequest, [busArg("s", %value)])
  of PasskeyPrompt:
    if value.len notin 1 .. 6 or not value.allCharsInSet(Digits):
      raise newException(ValueError, "Passkey must contain 1-6 digits")
    sendReply(session.connection, session.agentRequest, [busArg("u", %parseUInt(value))])
  of ConfirmPrompt:
    if value == "yes": sendReply(session.connection, session.agentRequest)
    elif value == "no":
      sendError(session.connection, session.agentRequest)
    else: raise newException(ValueError, "Confirmation must be yes or no")
  else: raise newException(ValueError, "No Bluetooth answer is pending")
  session.clearPrompt()
  session.state.error = ""

proc submit*(session: BtSession, command: BtCommand) =
  ## Apply one validated human command; background status remains independent.
  if session.closed: raise newException(IOError, "Bluetooth session is closed")
  session.state.error = ""
  if command.action == "status":
    session.refresh()
    return
  if command.action == "cancel":
    session.cancel()
    return
  if command.action == "reply":
    session.replyPrompt(command.value)
    return
  if not session.state.available: raise newException(IOError, "No Bluetooth adapter is available")
  if session.state.busy: raise newException(IOError, "A Bluetooth operation is already in progress")
  if session.hasRequest("registerAgent"):
    raise newException(IOError, "Bluetooth is finishing the previous request")
  if command.action == "scan":
    if not command.enabled:
      session.stopScan()
      return
    if not session.state.powered: raise newException(IOError, "Bluetooth is powered off")
    if session.scanOwned: return
    session.operation = "scan"
    session.queue("operation", session.adapter, AdapterInterface, "StartDiscovery")
    session.scanOwned = true
    session.scanAdapter = session.adapter
    session.scanDeadline = afterMs(session.limits.scanMs)
  elif command.action == "power":
    session.operation = "power"
    if not command.enabled: session.stopScan()
    session.queue("operation", session.adapter, PropertiesInterface, "Set",
      [busArg("s", %AdapterInterface), busArg("s", %"Powered"),
      busArg("v", variant("b", %command.enabled))])
  elif command.action in ["pair", "connect", "disconnect", "forget"]:
    if not validateAddress(command.address): raise newException(ValueError, "Invalid Bluetooth address")
    let address = command.address.toUpperAscii()
    if not session.paths.hasKey(address): raise newException(ValueError, "Bluetooth device is no longer available")
    session.devicePath = session.paths[address]
    session.deviceAddress = address
    session.operation = command.action
    case command.action
    of "pair":
      if session.agentRegistered:
        session.queue("operation", session.devicePath, DeviceInterface, "Pair", timeout = session.limits.pairMs)
      else:
        session.queue("registerAgent", "/org/bluez", AgentManagerInterface, "RegisterAgent",
          [busArg("o", %AgentPath), busArg("s", %"KeyboardDisplay")])
    of "connect", "disconnect":
      let methodName = if command.action == "connect": "Connect" else: "Disconnect"
      session.queue("operation", session.devicePath, DeviceInterface, methodName,
        timeout = session.limits.operationMs)
    of "forget":
      session.queue("operation", session.adapter, AdapterInterface, "RemoveDevice",
        [busArg("o", %session.devicePath)])
    else: discard
  else: raise newException(ValueError, "Unknown Bluetooth action")
  session.state.busy = true
  session.state.message = "Bluetooth " & command.action

proc completed(session: BtSession, tag: string, reply: ptr BusMessage) =
  ## Commit only successful daemon results; a successful pair alone permits trust.
  let
    failed = reply == nil or messageType(reply) == 3
    errorName = if reply == nil: "org.freedesktop.DBus.Error.Timeout" else: $messageErrorName(reply)
  if tag == "objects":
    if failed:
      session.objects = newJObject()
      session.bluezOwner = ""
      session.agentRegistered = false
      session.scanOwned = false
      if session.state.busy: session.cancel()
      session.state.error = "Bluetooth service unavailable: " & errorName
    else:
      let args = messageArgs(reply)
      if args.len != 1: raise newException(ValueError, "Invalid Bluetooth object snapshot")
      let owner = $messageSender(reply)
      if session.bluezOwner.len > 0 and session.bluezOwner != owner:
        session.agentRegistered = false
        session.scanOwned = false
        session.cancel()
      session.bluezOwner = owner
      session.objects = args[0]
      if session.state.message == "Checking Bluetooth": session.state.message = ""
      if session.state.error.startsWith("Bluetooth service unavailable:") or
          session.state.error == "No Bluetooth adapter is available":
        session.state.error = ""
    session.rebuildState()
    if not session.state.available and not failed:
      session.scanOwned = false
      if session.state.busy: session.cancel()
      session.state.error = "No Bluetooth adapter is available"
  elif tag == "pcms":
    session.pcms = newJObject()
    if failed:
      if errorName == "org.freedesktop.DBus.Error.UnknownMethod" and not session.modernPcms:
        # BlueALSA 4 replaced GetPCMs with the standard ObjectManager API.
        session.modernPcms = true
        session.nextRefresh = getMonoTime()
    else:
      let args = messageArgs(reply)
      if args.len == 1 and args[0].kind == JObject:
        if session.modernPcms:
          for path, interfaces in args[0]:
            if interfaces.hasKey("org.bluealsa.PCM1"):
              session.pcms[path] = interfaces["org.bluealsa.PCM1"]
        else: session.pcms = args[0]
    session.rebuildState()
  elif tag == "registerAgent":
    if failed: session.endOperation("Cannot register Bluetooth pairing agent: " & errorName)
    else:
      session.agentRegistered = true
      session.bluezOwner = $messageSender(reply)
      if session.operation == "pair":
        session.queue("operation", session.devicePath, DeviceInterface, "Pair", timeout = session.limits.pairMs)
  elif tag == "operation":
    if failed:
      let operation = session.operation
      if errorName.endsWith(".Timeout") or errorName.endsWith(".NoReply"):
        session.cancel()
      session.endOperation("Bluetooth " & operation & " failed: " & errorName)
    elif session.operation == "pair":
      session.clearPrompt()
      session.operation = "trust"
      session.queue("operation", session.devicePath, PropertiesInterface, "Set",
        [busArg("s", %DeviceInterface), busArg("s", %"Trusted"),
        busArg("v", variant("b", %true))])
    elif session.operation == "trust":
      session.operation = "connect"
      session.state.message = "Paired; connecting device"
      session.queue("operation", session.devicePath, DeviceInterface, "Connect",
        timeout = session.limits.operationMs)
    else:
      if session.operation == "scan":
        session.scanOwned = true
        session.scanDeadline = afterMs(session.limits.scanMs)
      session.state.message = if session.operation == "connect": "Connected" else: ""
      session.endOperation()
  elif tag == "stopScan":
    if not failed or errorName.endsWith(".NotReady"): session.scanOwned = false
    else:
      session.state.error = "Cannot stop Bluetooth scan: " & errorName
      session.scanDeadline = afterMs(session.limits.refreshMs)
  elif tag in ["cancelPair", "cancelConnect", "unregisterAgent"]:
    if failed and not errorName.endsWith(".DoesNotExist") and not errorName.endsWith(".NotConnected"):
      session.state.error = "Bluetooth cleanup failed: " & errorName

proc pump*(session: BtSession, waitMs = 0) =
  ## Dispatch the bus even while Pair or Connect waits for a human or remote device.
  if session.closed or session.connection == nil: return
  if connectionConnected(session.connection) == 0:
    for request in session.requests:
      pendingCancel(request.pending)
      pendingUnref(request.pending)
    session.requests.setLen(0)
    session.scanOwned = false
    session.agentRegistered = false
    session.operation = ""
    session.state.available = false
    session.state.busy = false
    session.state.error = "Bluetooth system bus disconnected"
    session.clearPrompt()
    return
  discard readWriteDispatch(session.connection, min(MaxDispatchMs, max(0, waitMs)).cint)
  var ready: seq[BusRequest]
  let now = getMonoTime()
  for index in countdown(session.requests.high, 0):
    let request = session.requests[index]
    if pendingCompleted(request.pending) != 0 or now >= request.deadline:
      ready.add request
      session.requests.delete(index)
  for request in ready:
    let reply = if pendingCompleted(request.pending) != 0:
      pendingStealReply(request.pending) else: nil
    if reply == nil: pendingCancel(request.pending)
    pendingUnref(request.pending)
    try: session.completed(request.tag, reply)
    finally:
      if reply != nil: messageUnref(reply)
  if session.state.prompt.kind != NoPrompt and now >= session.promptDeadline:
    session.cancel()
    session.state.error = "Bluetooth pairing prompt timed out"
  if session.scanOwned and now >= session.scanDeadline: session.stopScan()
  if now >= session.nextRefresh: session.refresh()

proc snapshotReady*(session: BtSession): bool =
  ## Report whether the initial authoritative status requests have completed.
  not session.hasRequest("objects") and not session.hasRequest("pcms")

proc close*(session: BtSession) =
  ## Cancel owned work and unregister only our agent before closing the private bus.
  if session == nil or session.closed: return
  try:
    session.cancel()
    if session.agentRegistered:
      session.queue("unregisterAgent", "/org/bluez", AgentManagerInterface,
        "UnregisterAgent", [busArg("o", %AgentPath)])
    let deadline = afterMs(800)
    while session.requests.len > 0 and getMonoTime() < deadline:
      session.nextRefresh = deadline
      session.pump(MaxDispatchMs)
  finally:
    session.closed = true
    for request in session.requests:
      pendingCancel(request.pending)
      pendingUnref(request.pending)
    session.requests.setLen(0)
    session.clearPrompt()
    removeFilter(session.connection, agentFilter, cast[pointer](session))
    connectionClose(session.connection)
    connectionUnref(session.connection)
    session.connection = nil
