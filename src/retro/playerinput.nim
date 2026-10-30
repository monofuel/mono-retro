import
  paddy, windy,
  ./[anbernic, touch]

const
  StickDpadThreshold* = 0.5'f32
  HorizontalDpad = (1'u16 shl 6) or (1'u16 shl 7)
  VerticalDpad = (1'u16 shl 4) or (1'u16 shl 5)
  RetroButtons* = [GamepadA, GamepadX, GamepadSelect, GamepadStart,
    GamepadUp, GamepadDown, GamepadLeft, GamepadRight, GamepadB, GamepadY,
    GamepadL1, GamepadR1, GamepadL2, GamepadR2, GamepadL3, GamepadR3]
  KeyboardButtons* = [(KeyZ, 0), (KeyBackspace, 2), (KeyEnter, 3),
    (KeyUp, 4), (KeyDown, 5), (KeyLeft, 6), (KeyRight, 7),
    (KeyX, 8), (KeyW, 9), (KeyQ, 1), (KeyA, 10), (KeyS, 11),
    (KeyPageUp, 12), (KeyPageDown, 13)]

proc overlayContact*(window: Window, desktop: bool, inputScreen: int,
    contacts: openArray[touch.TouchContact]): tuple[held: bool, x, y: float32, output: int] =
  ## Select desktop mouse or native touch without querying unsupported window properties.
  result.output = inputScreen
  if desktop:
    let position = window.mousePos
    result.held = window.buttonDown[MouseLeft]
    result.x = position.x.float32
    result.y = position.y.float32
  else:
    for contact in contacts:
      if contact.active:
        result = (true, contact.x.float32, contact.y.float32, 1)
        break

proc firstGamepad*(pads: seq[Gamepad]): Gamepad =
  ## Select the lowest device ID, or return an empty input snapshot.
  if pads.len == 0: return
  var chosen = 0
  for index, pad in pads:
    if pad.id < pads[chosen].id: chosen = index
  pads[chosen]

proc gamepadButtons*(pads: seq[Gamepad]): uint16 =
  ## Map RetroPad positions and the left stick, preferring digital D-pad axes.
  let
    pad = firstGamepad(pads)
    x = pad.axis(GamepadLStickX)
    y = pad.leftStickYUp()
  for index, button in RetroButtons:
    if pad.button(button): result = result or (1'u16 shl index)
  if (result and HorizontalDpad) == 0:
    if x <= -StickDpadThreshold: result = result or (1'u16 shl 6)
    elif x >= StickDpadThreshold: result = result or (1'u16 shl 7)
  if (result and VerticalDpad) == 0:
    if y >= StickDpadThreshold: result = result or (1'u16 shl 4)
    elif y <= -StickDpadThreshold: result = result or (1'u16 shl 5)

proc keyboardButtons*(held: set[Button]): uint16 =
  ## Map the desktop's documented keyboard controls to the same RetroPad.
  for (key, button) in KeyboardButtons:
    if key in held: result = result or (1'u16 shl button)
