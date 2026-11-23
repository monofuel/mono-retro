import
  std/[os, tempfiles],
  pixie,
  touchkeyboard,
  retro/[bluetooth, gamelibrary, libraryview, menuthemes, systeminfo]

proc main() =
  ## Exercise Bluetooth touch targets and controller actions across device sizes.
  let
    root = createTempDir("mono-retro-bluetooth-view-", "")
    paths = libraryPaths(root, root / "config.json")
    ui = newLibraryUi()
    index = LibraryIndex(version: LibraryVersion)
    power = PowerStatus(selected: "fixture")
  defer: removeDir(root)
  createDir("build/bluetooth")
  var view = BluetoothView(audioAddress: "00:11:22:33:44:55", audioName: "Headphones",
    keyboard: newTouchKeyboard(label = "Bluetooth PIN", submitLabel = "Pair", asciiOnly = true),
    state: BtState(available: true, powered: true, prompt: BtPrompt(kind: ConfirmPrompt,
      passkey: 123456, code: "123456", text: "Check this code on the other device.")))
  for position in 0 .. 7:
    view.state.devices.add BtDevice(address: "00:11:22:33:44:5" & $position,
      name: "Fixture " & $position, paired: true, connected: position == 0,
      audioReady: position == 0, batteryPercent: -1)
  view.device = view.state.devices[0]
  view.selected = view.state.devices.len
  doAssert ShowBluetooth in SettingsActions
  for theme in MenuTheme:
    for page in [BluetoothPage, BluetoothDevicePage, BluetoothPromptPage,
        BluetoothKeyboardPage, BluetoothForgetPage, AudioUnavailablePage]:
      var state = LibraryViewState(page: page, theme: theme, bluetooth: view, transition: 1)
      for dimensions in [(320, 240), (640, 480), (1024, 768)]:
        let layout = state.pageLayout(index, dimensions[0], dimensions[1])
        for item in layout.targets:
          doAssert item.area.x >= 0 and item.area.y >= 64
          doAssert item.area.x + item.area.width <= dimensions[0]
          doAssert item.area.y + item.area.height <= dimensions[1]
          let point = vec2((item.area.x + item.area.width div 2).float32,
            (item.area.y + item.area.height div 2).float32)
          doAssert layout.hitTarget(point).action == item.action
        for details in [false, true]:
          discard ui.renderLibrary(paths, index, state, power, dimensions[0], dimensions[1], details, @[])
      if page == BluetoothPromptPage:
        doAssert state.selectedTarget().action == RejectBluetoothPrompt
        state.moveSelection(index, 640, 480, 1, false)
        doAssert state.selectedTarget().action == AcceptBluetoothPrompt
      if page == BluetoothForgetPage:
        doAssert state.selectedTarget().action == ReturnBluetooth
      ui.renderLibrary(paths, index, state, power, 640, 480, false, @[]).writeFile(
        "build/bluetooth/view-" & $theme & "-" & $page & ".png")
  view.state.available = false
  view.state.error = "No Bluetooth adapter is available"
  let unavailable = LibraryViewState(page: BluetoothPage, theme: LibraryTheme, bluetooth: view)
  discard ui.renderLibrary(paths, index, unavailable, power, 320, 240, false, @[])

main()
