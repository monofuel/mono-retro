## Minimal touchkeyboard consumer: types a password with simulated taps and a
## controller press, then writes the rendered keyboard to a PNG.
##
## Run from the repository root: `nim r examples/touchkeyboard_demo.nim`.

import
  std/os,
  pixie,
  touchkeyboard

const
  FontPath = currentSourcePath().parentDir.parentDir / "assets" / "Roboto-Regular.ttf"
  OutputPath = "build/touchkeyboard-demo.png"

proc tapText(keyboard: var TouchKeyboard, area: Rect, text: string) =
  ## Tap each character's key as a touchscreen user would.
  for character in text:
    let layout = keyboard.keyboardLayout(area)
    for key in layout.keys:
      if key.action == InsertKey and key.text == $character:
        discard keyboard.tap(layout, vec2(key.area.x + key.area.w / 2, key.area.y + key.area.h / 2))
        break

proc main() =
  ## Drive the keyboard without any windowing or input library.
  let
    font = readFont(FontPath)
    area = rect(0, 0, 640, 480)
  var keyboard = newTouchKeyboard(label = "Password", submitLabel = "Connect")
  keyboard.tapText(area, "hunter22")
  let layout = keyboard.keyboardLayout(area)
  discard keyboard.moveFocus(layout, 0, 4)
  let image = newImage(640, 480)
  keyboard.render(image, layout, font)
  createDir(OutputPath.parentDir)
  image.writeFile(OutputPath)
  doAssert keyboard.text == "hunter22" and keyboard.displayText() == "••••••••"
  echo "Typed ", keyboard.text.len, " characters; wrote ", OutputPath

when isMainModule:
  main()
