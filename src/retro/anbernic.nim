import paddy

const
  ButtonMapping = [
    (GamepadA, GamepadB),
    (GamepadB, GamepadA),
    (GamepadC, GamepadX),
    (GamepadY, GamepadY),
    (GamepadX, GamepadL1),
    (GamepadZ, GamepadR1),
    (GamepadL1, GamepadSelect),
    (GamepadR1, GamepadStart),
    (GamepadL2, GamepadHome),
    (GamepadSelect, GamepadL2),
    (GamepadStart, GamepadR2),
    (GamepadUp, GamepadUp),
    (GamepadDown, GamepadDown),
    (GamepadLeft, GamepadLeft),
    (GamepadRight, GamepadRight)
  ]

proc remapButtons(buttons: uint64, dsPlus: bool): uint64 =
  ## Translate the vendor driver's assignments after Paddy's generic mapping.
  for (source, target) in ButtonMapping:
    if (buttons and (1'u64 shl source.int)) != 0:
      result = result or (1'u64 shl target.int)
  if dsPlus and (buttons and (1'u64 shl GamepadR2.int)) != 0:
    result = result or (1'u64 shl GamepadL3.int)

proc mapAnbernic*(pad: Gamepad): Gamepad =
  ## Keep handheld quirks in the application and use only Paddy's public API.
  if pad.name notin ["ANBERNIC-keys", "ANBERNIC-rk3568-keys"]:
    return pad
  let dsPlus = pad.name == "ANBERNIC-rk3568-keys"
  result = Gamepad(id: pad.id, name: pad.name,
    buttons: remapButtons(pad.buttons, dsPlus),
    pressed: remapButtons(pad.pressed, dsPlus),
    released: remapButtons(pad.released, dsPlus))
  if dsPlus:
    result.axes[GamepadLStickX.int] = pad.axis(GamepadLTrigger)
    result.axes[GamepadLStickY.int] = -pad.axis(GamepadRStickX)
  for button in [GamepadL2, GamepadR2]:
    let
      value = if result.button(button): 1.0'f else: 0.0'f
      axis = if button == GamepadL2: GamepadLTrigger else: GamepadRTrigger
    result.pressures[button.int] = value
    result.axes[axis.int] = value

proc leftStickYUp*(pad: Gamepad): float32 =
  ## Read an app-mapped pad's stick with positive Y pointing up.
  result = pad.axis(GamepadLStickY)
  when defined(linux):
    # Native evdev Y points down; the DS Plus adapter above already flips it.
    if pad.name != "ANBERNIC-rk3568-keys": result = -result
