import
  std/unittest,
  pixie,
  retro/[playerds, playeroverlay, playervideo]

suite "EarthBound viewport presentation":
  test "explicit crops, pixels and companion pointer across sizes":
    for (width, height) in [(256, 224), (320, 240), (336, 256), (448, 252), (512, 384),
        (1024, 1024), (257, 225)]:
      let geometry = earthboundGeometry(width, height)
      let image = newImage(width, height + 224)
      image.fill(rgbx(0, 0, 0, 255))
      for y in 0..<height:
        for x in 0..<width:
          image.data[y * width + x] = rgbx(uint8(x and 255), uint8(y and 255), 30, 255)
      for y in height..<height + 224:
        for x in geometry.companion.x..<geometry.companion.x + 256:
          image.data[y * width + x] = rgbx(uint8(x - geometry.companion.x),
            uint8(y - height), 60, 255)
      let game = dsScreen(image, nil, 0, geometry)
      let party = dsScreen(image, nil, 1, geometry)
      check game.width == width and game.height == height
      check party.width == 256 and party.height == 224
      for y in 0 ..< height:
        for x in 0 ..< width:
          check game[x, y] == rgbx(uint8(x and 255), uint8(y and 255), 30, 255)
      for y in 0 ..< 224:
        for x in 0 ..< 256:
          check party[x, y] == rgbx(x.uint8, y.uint8, 60, 255)
      check sameDsScreen(image, party, 1, geometry)
      if geometry.companion.x > 0:
        check geometry.inPadding(0, height)
        check image.data[height * width] == rgbx(0, 0, 0, 255)
      let pointer = dsPointer(SeparateDs, 1, 512, 448, 0, 0, true, geometry)
      check pointer.pressed
      check pointer.x == int16(((geometry.companion.x * 2 + 1) * 32767 div width) - 32767)
      check pointer.y == int16(((height * 2 + 1) * 32767 div (height + 224)) - 32767)
      check not dsPointer(SeparateDs, 1, 600, 500, 0, 0, true, geometry).pressed
      check not dsPointer(SeparateDs, 0, width, height, 0, 0, true, geometry).pressed
      let last = dsPointer(SeparateDs, 1, 512, 448, 511, 447, true, geometry)
      check last.pressed
      check last.x == int16((((geometry.companion.x + 255) * 2 + 1) * 32767 div width) - 32767)
      check last.y == int16((((height + 223) * 2 + 1) * 32767 div (height + 224)) - 32767)
      check not dsPointer(CombinedDs, 0, width, height + 224, 0, height - 1, true, geometry).pressed
      if geometry.companion.x > 0:
        check not dsPointer(CombinedDs, 0, width, height + 224, 0, height, true, geometry).pressed
      let overlay = newOverlayState()
      let normal = overlay.composeOverlay(image, 1, OverlaySeparate, true, width, height,
        geometry = geometry)
      check normal.crops == geometry.dualCrops()
      discard overlay.handleOverlay(OverlayToggle)
      let modal = overlay.composeOverlay(image, 1, OverlaySeparate, true, width, height,
        geometry = geometry)
      check modal.crops[0].width == width and modal.crops[0].height == height
      check modal.sourceImage.data[modal.crops[0].x] == rgbx(0, 0, 30, 255)

  test "strict options and forced integer scaling":
    check earthboundDsOptions(256, 224) == @[("decompbound_dual_screen", "enabled")]
    check earthboundDsOptions(336, 256) == @[("decompbound_dual_screen", "enabled"),
      ("decompbound_viewport_width", "336"), ("decompbound_viewport_height", "256")]
    for value in ["", "256", "256x", "256x224x1", "+256x224", "256x 224", "255x224", "256x1025"]:
      expect ValueError: discard parseEarthboundViewport(value)
    for value in ["", "0", "-1", "+2", "2x", "999999999999999999999"]:
      expect ValueError: discard parseEarthboundScale(value)
    check parseEarthboundViewport("257x225") == (257, 225)
    check parseEarthboundScale("auto").autoScale
    check parseEarthboundScale("3").scale == 3
    let geometry = earthboundGeometry(320, 240)
    check desktopWindowSizes(geometry.game, geometry.companion, 3, 2) == [(960, 720), (512, 448)]
    check frameViewport(320, 240, 1000, 800, 2).scale == 2
    check frameViewport(320, 240, 1000, 800).scale == 3
    expect ValueError: discard frameViewport(320, 240, 639, 480, 2)

  test "legacy DS remains equal stacked":
    let geometry = selectDualScreen(SeparateDs).geometry
    check geometry == stackedGeometry(256, 192)
    check dsPointer(SeparateDs, 1, 512, 384, 100, 200, true, geometry) ==
      dsPointer(SeparateDs, 1, 512, 384, 100, 200, true)
