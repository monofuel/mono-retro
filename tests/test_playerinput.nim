import
  paddy, windy,
  retro/[anbernic, playerinput]

proc held(buttons: openArray[GamepadButton]): uint64 =
  ## Pack public gamepad buttons into a snapshot.
  for button in buttons:
    result = result or (1'u64 shl button.int)

block:
  for name in AnbernicGamepadNames:
    let
      builtIn = Gamepad(id: 4, name: name, buttons: held([GamepadB]))
      external = Gamepad(id: 7, name: "Bluetooth controller", buttons: held([GamepadA]))
      ignored = Gamepad(id: 9, name: "Second controller", buttons: held([GamepadY]))
    doAssert playerGamepads(@[ignored, external, builtIn]) == @[builtIn, external]
    doAssert playerGamepads(@[external, builtIn, ignored]) == @[builtIn, external]
    doAssert gamepadButtons(@[ignored, builtIn, external]) == ((1'u16 shl 8) or 1)
    doAssert playerGamepads(@[builtIn]) == @[builtIn]
    doAssert playerGamepads(@[]).len == 0
    doAssert gamepadButtons(@[]) == 0

block:
  let
    builtIn = Gamepad(id: 5, name: "ANBERNIC-keys")
    lowerBuiltIn = Gamepad(id: 3, name: "ANBERNIC-rk3568-keys")
    external = Gamepad(id: 0, name: "External", buttons: held([GamepadR2]))
    ignored = Gamepad(id: 1, name: "Other", buttons: held([GamepadA]))
  doAssert playerGamepads(@[external, builtIn, lowerBuiltIn, ignored]) == @[lowerBuiltIn, external]
  doAssert playerControls({}, @[builtIn, external, ignored]).fastForward
  doAssert playerControls({}, @[builtIn, external, ignored]).buttons == 0
  doAssert gamepadButtons(@[builtIn, external]) == 1'u16 shl 13
  doAssert gamepadButtons(@[builtIn]) == 0
  doAssert not playerControls({}, @[builtIn]).fastForward
  doAssert gamepadButtons(@[builtIn, Gamepad(id: 8, name: "Reconnected")]) == 0
  doAssert playerGamepads(@[builtIn, Gamepad(id: 8, name: "Reconnected")])[1].id == 8

block:
  var
    builtIn = Gamepad(id: 0, name: "ANBERNIC-keys")
    external = Gamepad(id: 1, name: "External")
  builtIn.axes[GamepadLStickX.int] = -1
  external.buttons = held([GamepadRight])
  doAssert gamepadButtons(@[builtIn, external]) == 1'u16 shl 7
  external.buttons = 0
  external.axes[GamepadLStickX.int] = 1
  doAssert gamepadButtons(@[builtIn, external]) == 1'u16 shl 6
  builtIn.axes[GamepadLStickX.int] = 0
  doAssert gamepadButtons(@[builtIn, external]) == 1'u16 shl 7
  builtIn.buttons = held([GamepadDown])
  external.axes[GamepadLStickX.int] = 0
  external.axes[GamepadLStickY.int] = -1
  doAssert gamepadButtons(@[builtIn, external]) == 1'u16 shl 5
  builtIn.buttons = 0
  doAssert gamepadButtons(@[builtIn, external]) == 1'u16 shl 4
  doAssert gamepadButtons(@[builtIn]) == 0

block:
  var
    builtIn = Gamepad(id: 0, name: "ANBERNIC-keys", buttons: held([GamepadSelect]))
    external = Gamepad(id: 2, name: "External", buttons: held([GamepadStart]))
  doAssert not playerExitHeld(@[builtIn, external])
  builtIn.buttons = held([GamepadSelect, GamepadStart])
  doAssert playerExitHeld(@[builtIn, external])
  builtIn.buttons = 0
  external.buttons = held([GamepadSelect, GamepadStart])
  doAssert playerExitHeld(@[builtIn, external])
  doAssert not playerExitHeld(@[builtIn])
  doAssert not playerExitHeld(@[])
  builtIn.buttons = held([GamepadHome])
  external.pressed = held([GamepadL2, GamepadMisc0])
  doAssert playerButton(@[builtIn, external], GamepadHome)
  doAssert playerButtonPressed(@[builtIn, external], GamepadL2)
  doAssert playerButtonPressed(@[builtIn, external], GamepadMisc0)
  doAssert not playerButtonPressed(@[builtIn], GamepadL2)

block:
  let
    first = Gamepad(id: 2, name: "Desktop one", buttons: held([GamepadB]))
    second = Gamepad(id: 4, name: "Desktop two", buttons: held([GamepadA, GamepadHome]),
      pressed: held([GamepadL2]))
  doAssert playerGamepads(@[second, first]) == @[first]
  doAssert gamepadButtons(@[second, first]) == 1'u16 shl 8
  doAssert not playerButton(@[second, first], GamepadHome)
  doAssert not playerButtonPressed(@[second, first], GamepadL2)
  doAssert firstGamepad(@[second, first]) == first
  doAssert playerControls({KeyPageDown}, @[]).buttons == 1'u16 shl 13
  doAssert not playerControls({KeyPageDown}, @[]).fastForward
  doAssert playerControls({KeyTab}, @[]).fastForward

block:
  for name in AnbernicGamepadNames:
    var
      builtIn = Gamepad(id: 0, name: name)
      external = Gamepad(id: 4, name: "Xbox Wireless Controller")
    for (label, builtInButton, externalButton, other) in [
        ("A", GamepadB, GamepadA, "B"),
        ("B", GamepadA, GamepadB, "A")]:
      builtIn.buttons = held([builtInButton])
      builtIn.pressed = held([builtInButton])
      doAssert playerPhysicalButton(@[builtIn, external], label)
      doAssert playerPhysicalButton(@[builtIn, external], label, pressed = true)
      doAssert not playerPhysicalButton(@[builtIn, external], other)
      doAssert not playerPhysicalButton(@[builtIn, external], other, pressed = true)
      builtIn.buttons = 0
      builtIn.pressed = 0
      external.buttons = held([externalButton])
      external.pressed = held([externalButton])
      doAssert playerPhysicalButton(@[builtIn, external], label)
      doAssert playerPhysicalButton(@[builtIn, external], label, pressed = true)
      doAssert not playerPhysicalButton(@[builtIn, external], other)
      doAssert not playerPhysicalButton(@[builtIn, external], other, pressed = true)
      external.pressed = 0
      doAssert playerPhysicalButton(@[builtIn, external], label)
      doAssert not playerPhysicalButton(@[builtIn, external], label, pressed = true)
      doAssert not playerPhysicalButton(@[builtIn], label)
      external.buttons = 0
    let ignored = Gamepad(id: 5, name: "Second external",
      buttons: held([GamepadA, GamepadB]), pressed: held([GamepadA, GamepadB]))
    doAssert not playerPhysicalButton(@[ignored, external, builtIn], "A")
    doAssert not playerPhysicalButton(@[ignored, external, builtIn], "B", pressed = true)
    builtIn.buttons = held([GamepadA, GamepadHome, GamepadUp])
    builtIn.pressed = builtIn.buttons
    doAssert playerPhysicalButton(@[builtIn], "B", pressed = true)
    doAssert playerPhysicalButton(@[builtIn], "MENU")
    doAssert playerPhysicalButton(@[builtIn], "UP")
    doAssert not playerPhysicalButton(@[builtIn], "unknown")
  doAssert not playerPhysicalButton(@[], "A")

block:
  var
    builtIn = Gamepad(id: 0, name: "ANBERNIC-rk3568-keys",
      buttons: held([GamepadSelect]))
    external = Gamepad(id: 4, name: "External", buttons: held([GamepadStart]))
  doAssert playerExitController(@[builtIn, external]) == -1
  external.buttons = held([GamepadSelect, GamepadStart])
  doAssert playerExitController(@[builtIn, external]) == 4
  doAssert playerExitController(@[builtIn]) == -1
  external.id = 6
  doAssert playerExitController(@[builtIn, external]) == 6
  let idleExternal = Gamepad(id: 2, name: "First external")
  doAssert playerExitController(@[builtIn, idleExternal, external]) == -1
  builtIn.buttons = held([GamepadSelect, GamepadStart])
  doAssert playerExitController(@[external, builtIn]) == 0
  doAssert playerExitController(@[builtIn]) == 0
  builtIn.buttons = 0
  doAssert playerExitController(@[builtIn]) == -1
  doAssert playerExitController(@[]) == -1

block:
  var
    builtIn = Gamepad(id: 0, name: "ANBERNIC-rk3568-keys")
    external = Gamepad(id: 4, name: "External")
    ignored = Gamepad(id: 5, name: "Second external")
  builtIn.axes[GamepadLStickY.int] = -0.4'f32
  external.axes[GamepadLStickY.int] =
    when defined(linux): -0.8'f32 else: 0.8'f32
  ignored.axes[GamepadLStickY.int] = 1
  doAssert playerMenuStick(@[ignored, external, builtIn]) == 0.8'f32
  doAssert playerMenuStick(@[builtIn]) == -0.4'f32
  builtIn.axes[GamepadLStickY.int] = -0.8'f32
  doAssert playerMenuStick(@[external, builtIn]) == -0.8'f32
  builtIn.axes[GamepadLStickY.int] = 0.1'f32
  external.axes[GamepadLStickY.int] = 0
  doAssert playerMenuStick(@[builtIn, external]) == 0.1'f32
  builtIn.axes[GamepadLStickY.int] = 0
  doAssert playerMenuStick(@[builtIn]) == 0
  doAssert playerMenuStick(@[]) == 0
