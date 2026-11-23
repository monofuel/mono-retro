import
  paddy, windy,
  ./[anbernic, gamepad, touch]

const
  StickDpadThreshold* = 0.5'f32
  HorizontalDpad = (1'u16 shl 6) or (1'u16 shl 7)
  VerticalDpad = (1'u16 shl 4) or (1'u16 shl 5)
  RetroR2 = 1'u16 shl 13
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

proc playerGamepads*(pads: seq[Gamepad]): seq[Gamepad] =
  ## Use the built-in handheld pad and one external pad, or the first desktop pad.
  var
    builtIn = -1
    external = -1
  for index, pad in pads:
    if pad.isAnbernicGamepad():
      if builtIn < 0 or pad.id < pads[builtIn].id: builtIn = index
    elif external < 0 or pad.id < pads[external].id:
      external = index
  if builtIn >= 0: result.add pads[builtIn]
  if external >= 0: result.add pads[external]

proc playerButton*(pads: seq[Gamepad], button: GamepadButton): bool =
  ## Read a held button from either selected player-one controller.
  for pad in playerGamepads(pads):
    if pad.button(button): return true

proc playerButtonPressed*(pads: seq[Gamepad], button: GamepadButton): bool =
  ## Read a new press from either selected player-one controller.
  for pad in playerGamepads(pads):
    if pad.buttonPressed(button): return true

proc playerExitHeld*(pads: seq[Gamepad]): bool =
  ## Require Select and Start together on one selected controller for exit.
  for pad in playerGamepads(pads):
    if pad.button(GamepadSelect) and pad.button(GamepadStart): return true

proc playerExitController*(pads: seq[Gamepad]): int =
  ## Keep the exit hold tied to one physical controller across reconnects.
  for pad in playerGamepads(pads):
    if pad.button(GamepadSelect) and pad.button(GamepadStart): return pad.id
  -1

proc playerPhysicalButton*(pads: seq[Gamepad], label: string, pressed = false): bool =
  ## Apply each controller's own printed confirmation and back-button mapping.
  for pad in playerGamepads(pads):
    let button = physicalButton(pad.name, label)
    if button != GamepadButtonCount and
        (if pressed: pad.buttonPressed(button) else: pad.button(button)): return true

proc playerMenuStick*(pads: seq[Gamepad]): float32 =
  ## Use the strongest selected stick for menu navigation without filtering it.
  for pad in playerGamepads(pads):
    let value = pad.leftStickYUp()
    if abs(value) > abs(result): result = value

proc gamepadButtons*(pads: seq[Gamepad]): uint16 =
  ## Combine selected pads, preferring digital D-pad axes and then the built-in stick.
  let selected = playerGamepads(pads)
  for pad in selected:
    for index, button in RetroButtons:
      if pad.button(button): result = result or (1'u16 shl index)
  for pad in selected:
    let
      x = pad.axis(GamepadLStickX)
      y = pad.leftStickYUp()
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

proc playerControls*(held: set[Button], pads: seq[Gamepad]):
    tuple[buttons: uint16, fastForward: bool] =
  ## Reserve controller R2 and keyboard Tab for held fast-forward, keeping Page Down as core R2.
  let buttons = gamepadButtons(pads)
  result.buttons = keyboardButtons(held) or (buttons and not RetroR2)
  result.fastForward = (buttons and RetroR2) != 0 or KeyTab in held
