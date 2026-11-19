import
  std/[os, strutils, unicode],
  pixie,
  touchkeyboard

const
  FontPath = currentSourcePath().parentDir.parentDir / "assets" / "Roboto-Regular.ttf"

proc centre(key: KeyboardKey): Vec2 =
  ## Return the middle of a key's touch target.
  vec2(key.area.x + key.area.w / 2, key.area.y + key.area.h / 2)

proc findKey(layout: KeyboardLayout, action: KeyAction, text = ""): KeyboardKey =
  ## Locate a key by behaviour and inserted text.
  for key in layout.keys:
    if key.action == action and (text.len == 0 or key.text == text): return key
  raise newException(KeyError, "Missing key " & $action & " " & text)

proc testEditing() =
  ## Keep the cursor on code point boundaries through every edit.
  var keyboard = newTouchKeyboard("aé")
  doAssert keyboard.masked and not keyboard.revealed
  doAssert keyboard.cursor == "aé".len and keyboard.cursorRune == 2
  doAssert keyboard.insert("😀") == KeyboardEdited
  doAssert keyboard.text == "aé😀"
  doAssert keyboard.moveCursor(-2) == KeyboardChanged
  doAssert keyboard.cursorRune == 1 and keyboard.cursor == 1
  doAssert keyboard.insert("ß") == KeyboardEdited
  doAssert keyboard.text == "aßé😀" and keyboard.cursorRune == 2
  doAssert keyboard.deleteForward() == KeyboardEdited
  doAssert keyboard.text == "aß😀"
  doAssert keyboard.moveCursor(5) == KeyboardChanged
  doAssert keyboard.cursor == keyboard.text.len
  doAssert keyboard.backspace() == KeyboardEdited and keyboard.text == "aß"
  doAssert keyboard.backspace() == KeyboardEdited and keyboard.text == "a"
  doAssert keyboard.text.validateUtf8() == -1
  doAssert keyboard.moveCursor(1) == KeyboardIgnored
  doAssert keyboard.deleteForward() == KeyboardIgnored
  doAssert keyboard.insert("\n") == KeyboardIgnored
  doAssert keyboard.insert("\x7f") == KeyboardIgnored
  var raised = false
  try: discard keyboard.insert("\xff")
  except ValueError: raised = true
  doAssert raised and keyboard.text == "a"
  var limited = newTouchKeyboard(maxRunes = 2, asciiOnly = true)
  doAssert limited.insert("é") == KeyboardIgnored
  doAssert limited.insert("ab") == KeyboardEdited
  doAssert limited.insert("c") == KeyboardIgnored
  doAssert limited.text == "ab"
  limited.clear()
  doAssert limited.text == "" and limited.cursor == 0

proc testMasking() =
  ## Paint mask glyphs unless the user explicitly reveals the text.
  var keyboard = newTouchKeyboard("pässword")
  doAssert keyboard.displayText() == "••••••••"
  doAssert "p" notin keyboard.displayText()
  discard keyboard.moveCursor(-7)
  doAssert keyboard.displayCursor() == "•".len
  doAssert keyboard.pressAction(RevealKey) == KeyboardChanged
  doAssert keyboard.displayText() == "pässword" and keyboard.displayCursor() == 1
  doAssert keyboard.pressAction(RevealKey) == KeyboardChanged
  doAssert keyboard.displayText() == "••••••••"
  let plain = newTouchKeyboard("visible", masked = false)
  doAssert plain.displayText() == "visible"
  for key in plain.keyboardLayout(rect(0, 0, 640, 480)).keys:
    doAssert key.action != RevealKey

proc testKeys() =
  ## Exercise shift, symbols, space, backspace, submit and cancel through taps.
  var keyboard = newTouchKeyboard(submitLabel = "Connect")
  let area = rect(0, 0, 640, 480)
  var layout = keyboard.keyboardLayout(area)
  doAssert keyboard.tap(layout, layout.findKey(InsertKey, "q").centre) == KeyboardEdited
  doAssert keyboard.tap(layout, layout.findKey(ShiftKey).centre) == KeyboardChanged
  layout = keyboard.keyboardLayout(area)
  doAssert layout.findKey(InsertKey, "W").label == "W"
  doAssert keyboard.tap(layout, layout.findKey(InsertKey, "W").centre) == KeyboardEdited
  doAssert not keyboard.shift
  layout = keyboard.keyboardLayout(area)
  doAssert keyboard.tap(layout, layout.findKey(InsertKey, "e").centre) == KeyboardEdited
  discard keyboard.tap(layout, layout.findKey(ShiftKey).centre)
  discard keyboard.tap(keyboard.keyboardLayout(area), layout.findKey(ShiftKey).centre)
  doAssert keyboard.capsLock
  layout = keyboard.keyboardLayout(area)
  discard keyboard.tap(layout, layout.findKey(InsertKey, "R").centre)
  discard keyboard.tap(layout, layout.findKey(InsertKey, "T").centre)
  doAssert keyboard.capsLock
  discard keyboard.tap(layout, layout.findKey(ShiftKey).centre)
  doAssert not keyboard.capsLock and not keyboard.shift
  layout = keyboard.keyboardLayout(area)
  doAssert keyboard.tap(layout, layout.findKey(SpaceKey).centre) == KeyboardEdited
  doAssert keyboard.tap(layout, layout.findKey(ModeKey).centre) == KeyboardChanged
  layout = keyboard.keyboardLayout(area)
  doAssert keyboard.mode == SymbolsMode
  for symbol in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~":
    discard layout.findKey(InsertKey, $symbol)
  doAssert keyboard.tap(layout, layout.findKey(InsertKey, "@").centre) == KeyboardEdited
  doAssert keyboard.text == "qWeRT @"
  doAssert keyboard.tap(layout, layout.findKey(BackspaceKey).centre) == KeyboardEdited
  doAssert keyboard.text == "qWeRT "
  doAssert keyboard.tap(layout, layout.findKey(SubmitKey).centre) == KeyboardSubmitted
  doAssert layout.findKey(SubmitKey).label == "Connect"
  doAssert keyboard.tap(layout, layout.findKey(CancelKey).centre) == KeyboardCancelled
  doAssert keyboard.tap(layout, vec2(-5, -5)) == KeyboardIgnored

proc testLayout() =
  ## Keep targets inside the lower screen, non-overlapping and finger-sized.
  for (width, height, minimumHeight, minimumWidth) in [(640, 480, 60'f32, 40'f32),
      (720, 480, 60'f32, 45'f32), (320, 240, 28'f32, 20'f32), (1024, 768, 90'f32, 70'f32)]:
    for mode in KeyboardMode:
      var keyboard = newTouchKeyboard()
      keyboard.mode = mode
      let
        area = rect(0, 0, width.float32, height.float32)
        layout = keyboard.keyboardLayout(area)
      doAssert layout.rows.len == 5
      for index, key in layout.keys:
        doAssert key.area.x >= 0 and key.area.y >= layout.field.y + layout.field.h
        doAssert key.area.x + key.area.w <= width.float32 + 0.01
        doAssert key.area.y + key.area.h <= height.float32 + 0.01
        doAssert key.area.h >= minimumHeight, $width & " " & $key.area.h
        doAssert key.area.w >= minimumWidth, $width & " " & $key.area.w
        doAssert layout.keyAt(key.centre) == index
  let offset = newTouchKeyboard().keyboardLayout(rect(40, 200, 400, 240))
  for key in offset.keys:
    doAssert key.area.x >= 40 and key.area.y >= 200 and key.area.y + key.area.h <= 440.01

proc testNavigation() =
  ## Reach any key using a directional pad and activate it with one button.
  var keyboard = newTouchKeyboard()
  let layout = keyboard.keyboardLayout(rect(0, 0, 640, 480))
  doAssert layout.keys[keyboard.focusedKey(layout)].text == "1"
  discard keyboard.moveFocus(layout, 0, 1)
  doAssert layout.keys[keyboard.focusedKey(layout)].text == "q"
  discard keyboard.moveFocus(layout, -1, 0)
  doAssert layout.keys[keyboard.focusedKey(layout)].text == "p"
  doAssert keyboard.activateFocused(layout) == KeyboardEdited and keyboard.text == "p"
  discard keyboard.moveFocus(layout, 0, 10)
  doAssert keyboard.focusRow == 4
  var found = false
  for _ in 0 ..< layout.rows[4].len:
    if layout.keys[keyboard.focusedKey(layout)].action == SubmitKey:
      found = true
      break
    discard keyboard.moveFocus(layout, 1, 0)
  doAssert found and keyboard.activateFocused(layout) == KeyboardSubmitted
  keyboard.mode = SymbolsMode
  let symbols = keyboard.keyboardLayout(rect(0, 0, 640, 480))
  keyboard.focusRow = 3
  keyboard.focusColumn = 99
  keyboard.clampFocus(symbols)
  doAssert keyboard.focusColumn == symbols.rows[3].high

proc testRender() =
  ## Render masked and revealed states without painting the password.
  let font = readFont(FontPath)
  var keyboard = newTouchKeyboard("secret", label = "Password", submitLabel = "Connect")
  let
    image = newImage(640, 480)
    layout = keyboard.keyboardLayout(rect(0, 0, 640, 480))
  keyboard.render(image, layout, font)
  createDir("build")
  image.writeFile("build/touchkeyboard-masked.png")
  keyboard.revealed = true
  let revealed = newImage(640, 480)
  keyboard.render(revealed, layout, font)
  doAssert revealed.data != image.data
  let small = newImage(320, 240)
  keyboard.render(small, keyboard.keyboardLayout(rect(0, 0, 320, 240)), font)

testEditing()
testMasking()
testKeys()
testLayout()
testNavigation()
testRender()
