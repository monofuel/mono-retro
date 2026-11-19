# Reusing the touchscreen keyboard

`src/touchkeyboard.nim` is an MIT-licensed, standalone Nim module. It imports
the standard library and Pixie. It owns text editing, geometry, focus and
rendering; the consuming app owns windows and input devices. Anbernic-specific
input and Wi-Fi configuration stay in the launcher.

Use the checked-out `mono-retro/src` directory on the consumer's module path
and manage Pixie through its existing Nimby workspace. The current shared
workspace already registers that source path. For an independent checkout,
add its source path in the consumer's `config.nims` or use
`--path:/path/to/mono-retro/src`. This does not require syncing mono-retro's
whole application dependency lock into another app's shared workspace.

```nim
import
  pixie,
  touchkeyboard

var keyboard = newTouchKeyboard(masked = false, label = "Message", submitLabel = "Send")
let layout = keyboard.keyboardLayout(rect(0, 80, width.float32, height.float32 - 80))
case keyboard.tap(layout, touchPosition)
of KeyboardSubmitted:
  sendMessage(keyboard.text)
  keyboard.clear()
of KeyboardCancelled:
  keyboard.clear()
  closeInput()
else: discard
keyboard.render(image, layout, font)
```

The sample assumes the caller provides its image, font, dimensions, touch
position and application actions. Pass touch coordinates in the image's actual
pixel space after the existing input backend has handled rotation and scaling.
Recompute layout after resize or a Shift/symbol-page change. Controller input
uses `moveFocus` and `activateFocused`; physical text input uses `insert`.
Defaults mask text; choose `masked = false` for ordinary messages.

Nimdoc comments in [the module](../src/touchkeyboard.nim) define the API.
The model supports single-line UTF-8 text and edits whole code points; malformed
UTF-8 raises ValueError. The caller supplies a font with the glyphs it needs.
Text is not logged or persisted by the component.

Run `nim r tests/test_touchkeyboard.nim` for focused editing/input/layout checks.
`nim r examples/touchkeyboard_demo.nim` runs a minimal consumer without opening
any window and writes `build/touchkeyboard-demo.png`. The library is compiled
into each consumer; the demo and test executables are validation artifacts.
