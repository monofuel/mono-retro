## Standalone on-screen keyboard for touchscreens and controllers.
##
## The module owns the text model, key geometry, focus navigation and Pixie
## rendering. It does not read input devices or open windows: the caller
## translates its own touch, mouse, gamepad and physical keyboard events into
## `tap`, `moveFocus`, `activateFocused`, `pressAction` and `insert` calls, using
## coordinates already expressed in the target image's pixels.
##
## Text is UTF-8. The cursor is a byte offset that always lies on a code point
## boundary, and every editing operation preserves that invariant. Masking is
## enabled by default so passwords are never painted unless the user explicitly
## chooses Show.
##
## Minimal use:
##
## .. code-block:: nim
##   var keyboard = newTouchKeyboard(label = "Password", submitLabel = "Connect")
##   let layout = keyboard.keyboardLayout(rect(0, 0, 640, 480))
##   case keyboard.tap(layout, vec2(x, y))
##   of KeyboardSubmitted: use(keyboard.text)
##   of KeyboardCancelled: discard
##   else: discard
##   keyboard.render(image, keyboard.keyboardLayout(rect(0, 0, 640, 480)), font)

import
  std/[strutils, unicode],
  pixie

type
  KeyboardMode* = enum
    ## Character page shown by the keyboard.
    LettersMode, SymbolsMode
  KeyAction* = enum
    ## Behaviour of one key.
    InsertKey, ShiftKey, ModeKey, SpaceKey, BackspaceKey, RevealKey,
    CursorLeftKey, CursorRightKey, SubmitKey, CancelKey
  KeyboardKey* = object
    ## One touch target. `text` is the inserted text for `InsertKey`.
    action*: KeyAction
    text*: string
    label*: string
    area*: Rect
  KeyboardLayout* = object
    ## Geometry shared by rendering, hit testing and controller navigation.
    ## `rows` holds indices into `keys`, top row first.
    area*, field*: Rect
    keys*: seq[KeyboardKey]
    rows*: seq[seq[int]]
  KeyboardResult* = enum
    ## Outcome of one input. `KeyboardChanged` means only presentation changed.
    KeyboardIgnored, KeyboardChanged, KeyboardEdited, KeyboardSubmitted, KeyboardCancelled
  KeyboardTheme* = object
    ## Colours used by `render`.
    background*, field*, key*, special*, focused*, text*, muted*, accent*: Color
  TouchKeyboard* = object
    ## Editable text, presentation state and controller focus.
    textValue: string
    cursorValue: int
    masked*: bool
    revealed*: bool
    shift*: bool
    capsLock*: bool
    asciiOnly*: bool
    mode*: KeyboardMode
    maxRunes*: int
    focusRow*, focusColumn*: int
    label*: string
    submitLabel*: string

const
  LetterRows = ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm"]
  SymbolRows = ["1234567890", "!@#$%^&*()", "-_=+[]{};:<>", "'\",./?\\|~`"]
  MaskCharacter = "•"
  KeyGapDivisor = 160
  MinimumGap = 3
  MinimumFieldHeight = 32
  MaximumFieldHeight = 64
  KeyRows = 5
  DefaultTheme* = KeyboardTheme(
    background: color(0.07, 0.10, 0.14, 1), field: color(0.13, 0.18, 0.25, 1),
    key: color(0.16, 0.23, 0.31, 1), special: color(0.11, 0.16, 0.22, 1),
    focused: color(0.16, 0.37, 0.62, 1), text: color(0.92, 0.94, 0.97, 1),
    muted: color(0.62, 0.69, 0.76, 1), accent: color(0.40, 0.78, 0.68, 1))
    ## Dark palette suitable for handheld screens.

proc newTouchKeyboard*(text = "", masked = true, label = "",
    submitLabel = "Done", maxRunes = 0, asciiOnly = false): TouchKeyboard =
  ## Create a keyboard with the cursor at the end of `text`. A `maxRunes` of
  ## zero means unlimited. Raises ValueError when `text` is not valid UTF-8.
  if text.validateUtf8() != -1: raise newException(ValueError, "Keyboard text must be valid UTF-8")
  TouchKeyboard(textValue: text, cursorValue: text.len, masked: masked,
    label: label, submitLabel: submitLabel, maxRunes: maxRunes, asciiOnly: asciiOnly)

proc text*(keyboard: TouchKeyboard): string =
  ## Return the current UTF-8 text.
  keyboard.textValue

proc cursor*(keyboard: TouchKeyboard): int =
  ## Return the cursor as a byte offset on a code point boundary.
  keyboard.cursorValue

proc cursorRune*(keyboard: TouchKeyboard): int =
  ## Return the cursor as a code point index.
  keyboard.textValue[0 ..< keyboard.cursorValue].runeLen

proc clear*(keyboard: var TouchKeyboard) =
  ## Erase the text and overwrite its storage before releasing it.
  for index in 0 ..< keyboard.textValue.len: keyboard.textValue[index] = '\0'
  keyboard.textValue.setLen(0)
  keyboard.cursorValue = 0
  keyboard.revealed = false

proc setText*(keyboard: var TouchKeyboard, text: string) =
  ## Replace the text and move the cursor to its end. Raises ValueError for
  ## invalid UTF-8.
  if text.validateUtf8() != -1: raise newException(ValueError, "Keyboard text must be valid UTF-8")
  keyboard.clear()
  keyboard.textValue = text
  keyboard.cursorValue = text.len

proc previousBoundary(text: string, offset: int): int =
  ## Find the start of the code point before `offset`.
  result = offset
  if result <= 0: return 0
  dec result
  while result > 0 and (text[result].uint8 and 0xC0) == 0x80: dec result

proc nextBoundary(text: string, offset: int): int =
  ## Find the end of the code point starting at `offset`.
  if offset >= text.len: return text.len
  min(text.len, offset + max(1, text.runeLenAt(offset)))

proc acceptable(keyboard: TouchKeyboard, rune: Rune): bool =
  ## Reject control characters and, when requested, anything outside printable ASCII.
  let value = rune.int
  if value < 0x20 or value == 0x7f or value in 0x80 .. 0x9f: return false
  not keyboard.asciiOnly or value < 0x7f

proc insert*(keyboard: var TouchKeyboard, value: string): KeyboardResult =
  ## Insert UTF-8 text at the cursor. Control characters, characters rejected by
  ## `asciiOnly` and input beyond `maxRunes` are ignored as a whole. Raises
  ## ValueError for invalid UTF-8.
  if value.validateUtf8() != -1: raise newException(ValueError, "Inserted text must be valid UTF-8")
  if value.len == 0: return KeyboardIgnored
  for rune in value.runes:
    if not keyboard.acceptable(rune): return KeyboardIgnored
  if keyboard.maxRunes > 0 and keyboard.textValue.runeLen + value.runeLen > keyboard.maxRunes:
    return KeyboardIgnored
  keyboard.textValue.insert(value, keyboard.cursorValue)
  keyboard.cursorValue += value.len
  KeyboardEdited

proc backspace*(keyboard: var TouchKeyboard): KeyboardResult =
  ## Delete the code point before the cursor.
  if keyboard.cursorValue == 0: return KeyboardIgnored
  let start = previousBoundary(keyboard.textValue, keyboard.cursorValue)
  keyboard.textValue.delete(start ..< keyboard.cursorValue)
  keyboard.cursorValue = start
  KeyboardEdited

proc deleteForward*(keyboard: var TouchKeyboard): KeyboardResult =
  ## Delete the code point after the cursor.
  if keyboard.cursorValue >= keyboard.textValue.len: return KeyboardIgnored
  keyboard.textValue.delete(keyboard.cursorValue ..< nextBoundary(keyboard.textValue, keyboard.cursorValue))
  KeyboardEdited

proc moveCursor*(keyboard: var TouchKeyboard, runes: int): KeyboardResult =
  ## Move the cursor by whole code points, stopping at either end.
  let before = keyboard.cursorValue
  for _ in 0 ..< abs(runes):
    keyboard.cursorValue = if runes < 0: previousBoundary(keyboard.textValue, keyboard.cursorValue)
      else: nextBoundary(keyboard.textValue, keyboard.cursorValue)
  if keyboard.cursorValue == before: KeyboardIgnored else: KeyboardChanged

proc displayText*(keyboard: TouchKeyboard): string =
  ## Return the text as it may be painted: one mask glyph per code point unless revealed.
  if keyboard.masked and not keyboard.revealed: MaskCharacter.repeat(keyboard.textValue.runeLen)
  else: keyboard.textValue

proc displayCursor*(keyboard: TouchKeyboard): int =
  ## Return the cursor's byte offset within `displayText`.
  if keyboard.masked and not keyboard.revealed: keyboard.cursorRune * MaskCharacter.len
  else: keyboard.cursorValue

proc keyLabel(keyboard: TouchKeyboard, action: KeyAction): string =
  ## Name special keys with words that the bundled Latin fonts can render.
  case action
  of ShiftKey: (if keyboard.capsLock: "CAPS" else: "Shift")
  of ModeKey: (if keyboard.mode == LettersMode: "#+=" else: "ABC")
  of SpaceKey: "space"
  of BackspaceKey: "Del"
  of RevealKey: (if keyboard.revealed: "Hide" else: "Show")
  of CursorLeftKey: "‹"
  of CursorRightKey: "›"
  of SubmitKey: keyboard.submitLabel
  of CancelKey: "Cancel"
  of InsertKey: ""

proc keyboardLayout*(keyboard: TouchKeyboard, area: Rect): KeyboardLayout =
  ## Divide `area` into a text field and five full-width key rows. Keys never
  ## overlap and every key lies inside `area`.
  let
    gap = max(MinimumGap.float32, floor(area.w / KeyGapDivisor.float32))
    fieldHeight = clamp(floor(area.h * 0.14), MinimumFieldHeight.float32, MaximumFieldHeight.float32)
    rowHeight = floor((area.h - fieldHeight - gap * KeyRows.float32) / KeyRows.float32)
    shifted = keyboard.shift or keyboard.capsLock
    characters = if keyboard.mode == LettersMode: LetterRows else: SymbolRows
  result.area = area
  result.field = rect(area.x, area.y, area.w, fieldHeight)
  var rows: seq[seq[(KeyAction, string, float32)]]
  for number, row in characters:
    var keys: seq[(KeyAction, string, float32)]
    if number == 3 and keyboard.mode == LettersMode: keys.add (ShiftKey, "", 1.5'f32)
    for character in row:
      let value = if shifted and keyboard.mode == LettersMode: $character.toUpperAscii() else: $character
      keys.add (InsertKey, value, 1'f32)
    if number == 3: keys.add (BackspaceKey, "", 1.5'f32)
    rows.add keys
  var bottom = @[(ModeKey, "", 1.5'f32)]
  if keyboard.masked: bottom.add (RevealKey, "", 1.5'f32)
  bottom.add [(CursorLeftKey, "", 1'f32), (SpaceKey, " ", 3'f32), (CursorRightKey, "", 1'f32),
    (CancelKey, "", 1.5'f32), (SubmitKey, "", 2'f32)]
  rows.add bottom
  for number, row in rows:
    var total = 0'f32
    for key in row: total += key[2]
    let
      unit = (area.w - gap * (row.len - 1).float32) / total
      y = area.y + fieldHeight + gap + number.float32 * (rowHeight + gap)
    var
      x = area.x
      indices: seq[int]
    for position, key in row:
      let width = if position == row.high: area.x + area.w - x else: floor(unit * key[2])
      indices.add result.keys.len
      result.keys.add KeyboardKey(action: key[0], text: key[1],
        label: if key[0] == InsertKey: key[1] else: keyboard.keyLabel(key[0]),
        area: rect(x, y, width, rowHeight))
      x += width + gap
    result.rows.add indices

proc keyAt*(layout: KeyboardLayout, point: Vec2): int =
  ## Return the index of the key containing `point`, or -1.
  for index, key in layout.keys:
    if point.x >= key.area.x and point.y >= key.area.y and
        point.x < key.area.x + key.area.w and point.y < key.area.y + key.area.h:
      return index
  -1

proc clampFocus*(keyboard: var TouchKeyboard, layout: KeyboardLayout) =
  ## Keep controller focus on an existing key after the layout changes.
  if layout.rows.len == 0: return
  keyboard.focusRow = clamp(keyboard.focusRow, 0, layout.rows.high)
  keyboard.focusColumn = clamp(keyboard.focusColumn, 0, layout.rows[keyboard.focusRow].high)

proc focusedKey*(keyboard: TouchKeyboard, layout: KeyboardLayout): int =
  ## Return the index of the controller-focused key, or -1 for an empty layout.
  if layout.rows.len == 0: return -1
  let row = layout.rows[clamp(keyboard.focusRow, 0, layout.rows.high)]
  row[clamp(keyboard.focusColumn, 0, row.high)]

proc moveFocus*(keyboard: var TouchKeyboard, layout: KeyboardLayout, dx, dy: int): KeyboardResult =
  ## Move controller focus. Horizontal movement wraps within a row; vertical
  ## movement picks the key in the next row whose centre is closest.
  if layout.rows.len == 0: return KeyboardIgnored
  keyboard.clampFocus(layout)
  if dx != 0:
    let count = layout.rows[keyboard.focusRow].len
    keyboard.focusColumn = ((keyboard.focusColumn + dx) mod count + count) mod count
  if dy != 0:
    let
      current = layout.keys[keyboard.focusedKey(layout)].area
      centre = current.x + current.w / 2
      row = clamp(keyboard.focusRow + dy, 0, layout.rows.high)
    var best = 0
    for column, index in layout.rows[row]:
      let area = layout.keys[index].area
      let bestArea = layout.keys[layout.rows[row][best]].area
      if abs(area.x + area.w / 2 - centre) < abs(bestArea.x + bestArea.w / 2 - centre): best = column
    keyboard.focusRow = row
    keyboard.focusColumn = best
  KeyboardChanged

proc pressKey*(keyboard: var TouchKeyboard, key: KeyboardKey): KeyboardResult =
  ## Apply one key from a layout produced for this keyboard's current state.
  case key.action
  of InsertKey, SpaceKey:
    result = keyboard.insert(key.text)
    if result == KeyboardEdited and keyboard.shift and not keyboard.capsLock: keyboard.shift = false
  of ShiftKey:
    if keyboard.capsLock:
      keyboard.capsLock = false
      keyboard.shift = false
    elif keyboard.shift: keyboard.capsLock = true
    else: keyboard.shift = true
    result = KeyboardChanged
  of ModeKey:
    keyboard.mode = if keyboard.mode == LettersMode: SymbolsMode else: LettersMode
    result = KeyboardChanged
  of BackspaceKey: result = keyboard.backspace()
  of RevealKey:
    keyboard.revealed = not keyboard.revealed
    result = KeyboardChanged
  of CursorLeftKey: result = keyboard.moveCursor(-1)
  of CursorRightKey: result = keyboard.moveCursor(1)
  of SubmitKey: result = KeyboardSubmitted
  of CancelKey: result = KeyboardCancelled

proc pressAction*(keyboard: var TouchKeyboard, action: KeyAction): KeyboardResult =
  ## Apply a special key without a layout, for controller shortcuts.
  ## `InsertKey` is ignored; use `insert` for text.
  if action == InsertKey: return KeyboardIgnored
  keyboard.pressKey(KeyboardKey(action: action, text: if action == SpaceKey: " " else: ""))

proc activateFocused*(keyboard: var TouchKeyboard, layout: KeyboardLayout): KeyboardResult =
  ## Press the controller-focused key.
  let index = keyboard.focusedKey(layout)
  if index < 0: return KeyboardIgnored
  keyboard.pressKey(layout.keys[index])

proc tap*(keyboard: var TouchKeyboard, layout: KeyboardLayout, point: Vec2): KeyboardResult =
  ## Press the key under a completed tap and move controller focus to it.
  let index = layout.keyAt(point)
  if index < 0: return KeyboardIgnored
  for row, indices in layout.rows:
    let column = indices.find(index)
    if column >= 0:
      keyboard.focusRow = row
      keyboard.focusColumn = column
  keyboard.pressKey(layout.keys[index])

proc fill(image: Image, area: Rect, tint: Color) =
  ## Paint a solid rectangle.
  let context = newContext(image)
  context.fillStyle = tint
  context.fillRect(area)

proc render*(keyboard: TouchKeyboard, image: Image, layout: KeyboardLayout,
    font: Font, theme = DefaultTheme) =
  ## Paint the field and keys into `image` with the caller's font. The font's
  ## size and paint are modified.
  let caretFocus = keyboard.focusedKey(layout)
  image.fill(layout.area, theme.background)
  image.fill(layout.field, theme.field)
  let
    padding = max(6'f32, layout.field.h * 0.2)
    textSize = max(12'f32, layout.field.h * 0.45)
    shown = keyboard.displayText()
    labelWidth = if keyboard.label.len > 0: layout.field.w * 0.28 else: 0'f32
    textArea = rect(layout.field.x + padding + labelWidth, layout.field.y,
      max(1'f32, layout.field.w - padding * 2 - labelWidth), layout.field.h)
  font.size = textSize
  if keyboard.label.len > 0:
    font.paint.color = theme.muted
    image.fillText(font.typeset(keyboard.label, bounds = vec2(labelWidth, layout.field.h),
      vAlign = MiddleAlign, wrap = false), translate(vec2(layout.field.x + padding, layout.field.y)))
  let
    caretX = font.typeset(shown[0 ..< keyboard.displayCursor()]).layoutBounds().x
    offset = max(0'f32, caretX - textArea.w + 2)
    content = newImage(max(1, textArea.w.int), max(1, textArea.h.int))
  font.paint.color = theme.text
  content.fillText(font.typeset(shown, bounds = vec2(0, textArea.h), vAlign = MiddleAlign, wrap = false),
    translate(vec2(-offset, 0)))
  content.fill(rect(caretX - offset, textArea.h * 0.2, 2, textArea.h * 0.6), theme.accent)
  image.draw(content, translate(vec2(textArea.x, textArea.y)))
  for index, key in layout.keys:
    let special = key.action notin {InsertKey, SpaceKey}
    var tint = if special: theme.special else: theme.key
    if key.action == ShiftKey and (keyboard.shift or keyboard.capsLock): tint = theme.accent
    if index == caretFocus:
      image.fill(key.area, theme.accent)
      image.fill(rect(key.area.x + 2, key.area.y + 2, max(1'f32, key.area.w - 4),
        max(1'f32, key.area.h - 4)), theme.focused)
    else:
      image.fill(key.area, tint)
    font.size = clamp(key.area.h * 0.42, 10, 30)
    let natural = font.typeset(key.label, wrap = false).layoutBounds().x
    if natural > key.area.w * 0.86: font.size = max(8'f32, font.size * key.area.w * 0.86 / natural)
    font.paint.color = theme.text
    image.fillText(font.typeset(key.label, bounds = vec2(key.area.w, key.area.h),
      hAlign = CenterAlign, vAlign = MiddleAlign, wrap = false),
      translate(vec2(key.area.x, key.area.y)))
