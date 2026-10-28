import
  paddy, windy

const
  RetroButtons* = [GamepadA, GamepadY, GamepadSelect, GamepadStart,
    GamepadUp, GamepadDown, GamepadLeft, GamepadRight, GamepadB, GamepadX,
    GamepadL1, GamepadR1, GamepadL2, GamepadR2, GamepadL3, GamepadR3]
  KeyboardButtons* = [(KeyZ, 0), (KeyBackspace, 2), (KeyEnter, 3),
    (KeyUp, 4), (KeyDown, 5), (KeyLeft, 6), (KeyRight, 7),
    (KeyX, 8), (KeyW, 9), (KeyQ, 1), (KeyA, 10), (KeyS, 11)]

proc firstGamepad*(pads: seq[Gamepad]): Gamepad =
  ## Select the lowest device ID, or return an empty input snapshot.
  if pads.len == 0: return
  var chosen = 0
  for index, pad in pads:
    if pad.id < pads[chosen].id: chosen = index
  pads[chosen]

proc gamepadButtons*(pads: seq[Gamepad]): uint16 =
  ## Map one controller's physical positions to the standard RetroPad layout.
  let pad = firstGamepad(pads)
  for index, button in RetroButtons:
    if pad.button(button): result = result or (1'u16 shl index)

proc keyboardButtons*(held: set[Button]): uint16 =
  ## Map the desktop's documented keyboard controls to the same RetroPad.
  for (key, button) in KeyboardButtons:
    if key in held: result = result or (1'u16 shl button)
