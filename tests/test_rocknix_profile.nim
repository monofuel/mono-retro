import
  paddy,
  retro/[anbernic, gamepad, settings]

let profile = parseSettings(@["--device:rg-ds-plus-rocknix"])
doAssert profile.display == "drm" and profile.outputs == @["DSI-1", "DSI-2"]
doAssert profile.touchName == "Goodix Capacitive TouchScreen"
doAssert profile.batterySupply == "battery"
doAssert profile.sticks.len == 1 and profile.sticks[0].x == 0 and profile.sticks[0].y == 1
doAssert identifyDevice("anbernic,rg-ds-plus\0rockchip,rk3568", @["retrogame_joypad"], "", 2) == rgDsPlusRocknixDevice
doAssert identifyDevice("rockchip,rk3568", @["retrogame_joypad"], "", 2) == genericDevice
doAssert parseSettings(@[], rgDsPlusRocknixDevice).touchName == profile.touchName
doAssert physicalButton("retrogame_joypad", "A") == GamepadB
doAssert physicalButton("retrogame_joypad", "B") == GamepadA
doAssert physicalButton("retrogame_joypad", "X") == GamepadY
doAssert physicalButton("retrogame_joypad", "Y") == GamepadX
var pad = Gamepad(id: 1, name: "retrogame_joypad", buttons: 1'u64 shl GamepadB.int)
pad.axes[GamepadLStickY.int] = 0.5
let mapped = pad.mapAnbernic()
doAssert mapped.buttons == pad.buttons
doAssert mapped.axis(GamepadLStickY) == -0.5
doAssert mapped.leftStickYUp() == -0.5
doAssert parseSettings(@[], rgDsPlusDevice).touchName == "gt9xx-0"
