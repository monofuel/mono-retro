import std/unittest
import pixie
import retro/[playeroverlay, ra_types]

suite "Achievement overlay ownership and routing":
  test "normal frames remain borrowed and duplicate UI revisions remain stable":
    let state = newOverlayState()
    let image = newImage(256, 448)
    image.fill(rgbx(12, 34, 56, 255))
    let initial = state.composeOverlay(image, 1, OverlaySeparate, true, 256, 224, 1)
    check initial.sourceImage == image
    check initial.crops == [(0, 0, 256, 224), (0, 224, 256, 224)]
    let duplicate = state.composeOverlay(image, 2, OverlaySeparate, true, 256, 224, 1, false)
    check not duplicate.changed
    check duplicate.revision == initial.revision
    check state.handleOverlay(OverlayToggle) == OverlayOpened
    let modal = state.composeOverlay(image, 2, OverlaySeparate, true, 256, 224, 1, false)
    check modal.changed
    check modal.sourceImage != image
    check modal.sourceImage.width == 512 and modal.sourceImage.height == 608
    check modal.crops == [(128, 0, 256, 224), (0, 224, 512, 384)]
    check modal.sourceImage.data[128] == rgbx(12, 34, 56, 255)
    image.fill(rgbx(99, 88, 77, 255))
    let held = state.composeOverlay(image, 3, OverlaySeparate, true, 256, 224, 1, false)
    check held.sourceImage.data[128] == rgbx(12, 34, 56, 255)
    check not held.changed
    check state.handleOverlay(OverlayToggle) == OverlayClosed
    let resumed = state.composeOverlay(image, 3, OverlaySeparate, true, 256, 224, 1, false)
    check resumed.changed and resumed.sourceImage == image

  test "metadata preserves the list; controls and pointer use the rendered layout":
    let state = newOverlayState()
    var snapshot = RaSnapshot(status: RaReady, gameTitle: "Synthetic", hasList: true)
    for index in 0 ..< 8:
      snapshot.achievements.add(RaAchievement(id: index.uint32 + 1,
        title: "Item " & $index, description: "Invented description.", points: 5))
    state.setSnapshot(snapshot)
    state.setSnapshot(RaSnapshot(status: RaReady, gameTitle: "Synthetic", total: 8))
    check state.handleOverlay(OverlayToggle) == OverlayOpened
    check state.handleOverlay(OverlayPageNext) == OverlayChanged
    check state.selectedIndex == 4
    let image = newImage(256, 448)
    image.fill(rgbx(0, 0, 0, 255))
    let modal = state.composeOverlay(image, 1, OverlaySeparate, true, 256, 224)
    let point = modal.overlayPointer(1, 1024, 768, 100, 220)
    check point.inside and point.x == 50 and point.y == 110
    check not modal.overlayPointer(0, 1024, 768, 100, 220).inside
    check state.pointerOverlay(point.x, point.y) == OverlayChanged
    check state.showingDetails
    check state.selectedIndex == 4
    check state.handleOverlay(OverlayBack) == OverlayChanged
    check not state.showingDetails
    check state.handleOverlay(OverlayBack) == OverlayClosed
    state.setSnapshot(RaSnapshot(status: RaReady, gameTitle: "Other game"))
    check state.selectedIndex == -1

  test "toasts own pixels, expire on duplicates and pause while modal":
    let state = newOverlayState()
    let image = newImage(256, 224)
    image.fill(rgbx(30, 40, 50, 255))
    state.enqueueNotices([RaNotice(title: "Synthetic unlock", description: "Invented.", points: 5)])
    state.updateOverlay(0)
    let toast = state.composeOverlay(image, 1, OverlaySingle)
    check toast.sourceImage != image
    for pixel in image.data: check pixel == rgbx(30, 40, 50, 255)
    for pixel in toast.sourceImage.data: check pixel.a == 255
    discard state.handleOverlay(OverlayToggle)
    state.updateOverlay(10_000_000_000)
    discard state.handleOverlay(OverlayToggle)
    state.updateOverlay(10_000_000_001)
    check state.composeOverlay(image, 1, OverlaySingle, changed = false).sourceImage != image
    state.updateOverlay(15_000_000_000)
    let expired = state.composeOverlay(image, 1, OverlaySingle, changed = false)
    check expired.sourceImage == image and expired.changed

  test "small desktop outputs fit the panel and use matching pointer coordinates":
    let state = newOverlayState()
    discard state.handleOverlay(OverlayToggle)
    let modal = state.composeOverlay(nil, 0, OverlaySingle)
    let small = modal.fitComposition(0, 128, 96)
    check small.width == 128 and small.height == 96
    let point = modal.overlayPointer(0, 128, 96, 64, 48)
    check point.inside and point.x == 256 and point.y == 192
    let combined = state.composeOverlay(newImage(256, 448), 1, OverlayCombined, true, 256, 224)
    check combined.uiOutput == 0
    check not combined.overlayPointer(0, 512, 608, 256, 100).inside
    check combined.overlayPointer(0, 512, 608, 256, 400).inside
