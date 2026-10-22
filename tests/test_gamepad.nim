import
  paddy,
  retro/[anbernic, gamepad, input, settings]

block:
  let mapping = [
    (GamepadA, GamepadB), (GamepadB, GamepadA),
    (GamepadC, GamepadX), (GamepadY, GamepadY),
    (GamepadX, GamepadL1), (GamepadZ, GamepadR1),
    (GamepadL1, GamepadSelect), (GamepadR1, GamepadStart),
    (GamepadL2, GamepadHome), (GamepadSelect, GamepadL2),
    (GamepadStart, GamepadR2), (GamepadUp, GamepadUp),
    (GamepadDown, GamepadDown), (GamepadLeft, GamepadLeft),
    (GamepadRight, GamepadRight)
  ]
  for name in ["ANBERNIC-keys", "ANBERNIC-rk3568-keys"]:
    for (source, target) in mapping:
      let
        sourceBit = 1'u64 shl source.int
        targetBit = 1'u64 shl target.int
        pad = Gamepad(id: 3, name: name, buttons: sourceBit,
          pressed: sourceBit, released: sourceBit).mapAnbernic()
      doAssert pad.id == 3 and pad.name == name
      doAssert pad.buttons == targetBit
      doAssert pad.pressed == targetBit
      doAssert pad.released == targetBit

block:
  var pad = Gamepad(id: 1, name: "ANBERNIC-rk3568-keys")
  pad.buttons = (1'u64 shl GamepadR2.int) or (1'u64 shl GamepadSelect.int)
  pad.axes[GamepadLTrigger.int] = 0.5
  pad.axes[GamepadRStickX.int] = -0.75
  pad.axes[GamepadRStickY.int] = 1
  let mapped = pad.mapAnbernic()
  doAssert mapped.button(GamepadL3) and mapped.button(GamepadL2)
  doAssert not mapped.button(GamepadR2)
  doAssert mapped.axis(GamepadLStickX) == 0.5
  doAssert mapped.axis(GamepadLStickY) == 0.75
  doAssert mapped.axis(GamepadLTrigger) == 1
  doAssert mapped.buttonPressure(GamepadL2) == 1
  doAssert mapped.axis(GamepadRTrigger) == 0
  doAssert mapped.axis(GamepadRStickX) == 0
  doAssert mapped.axis(GamepadRStickY) == 0
  pad.name = "ANBERNIC-keys"
  let sp = pad.mapAnbernic()
  doAssert not sp.button(GamepadL3)
  doAssert sp.axis(GamepadLStickX) == 0
  doAssert sp.axis(GamepadLStickY) == 0
  pad.name = "Other controller"
  doAssert pad.mapAnbernic() == pad

block:
  doAssert parseSettings(@[]).gamepad == "paddy"
  doAssert parseSettings(@["--gamepad:raw"]).gamepad == "raw"
  var rejected = false
  try:
    discard parseSettings(@["--gamepad:other"])
  except ValueError:
    rejected = true
  doAssert rejected

block:
  let
    start = Binding(label: "START", device: "ANBERNIC-keys")
    a = Binding(label: "A", device: "ANBERNIC-keys")
    volume = Binding(label: "VOL+", device: "ANBERNIC-keys")
    back = Binding(label: "BACK", device: "adc-keys")
  var
    monitor: GamepadMonitor
    pad = Gamepad(id: 3, name: "ANBERNIC-keys")
  doAssert start.usesPaddy() and a.usesPaddy()
  doAssert not volume.usesPaddy() and not back.usesPaddy()
  doAssert not monitor.active(start)
  doAssert not monitor.observed(start)
  pad.buttons = (1'u64 shl GamepadStart.int) or (1'u64 shl GamepadB.int)
  pad.pressed = pad.buttons
  monitor.update(@[pad])
  doAssert monitor.active(start) and monitor.freshPress(start)
  doAssert monitor.active(a) and monitor.observed(a)
  pad.pressed = 0
  monitor.update(@[pad])
  doAssert monitor.active(start) and not monitor.freshPress(start)
  pad.buttons = 0
  monitor.update(@[pad])
  doAssert not monitor.active(start) and monitor.observed(start)
  monitor.update(@[])
  monitor.update(@[pad])
  doAssert not monitor.observed(start)
  pad.name = "ANBERNIC-rk3568-keys"
  pad.axes[GamepadLStickX.int] = 0.5
  pad.axes[GamepadLStickY.int] = -0.75
  monitor.update(@[pad])
  doAssert monitor.axisPosition(pad.name, GamepadLStickX) == 0.5
  doAssert monitor.axisPosition(pad.name, GamepadLStickY) == -0.75
  doAssert monitor.axisPosition("missing", GamepadLStickX) == 0

echo "Paddy tester integration tests passed"
