## Explicit dual-screen crop geometry shared by presentation, pointer and overlay.

import
  std/[sequtils, strutils]

type
  PanelCrop* = tuple[x, y, width, height: int]
  DualGeometry* = object
    frameWidth*, frameHeight*: int
    game*, companion*: PanelCrop

const
  EarthboundCompanionWidth* = 256
  EarthboundCompanionHeight* = 224
  EarthboundViewportMinWidth* = 256
  EarthboundViewportMaxWidth* = 1024
  EarthboundViewportMinHeight* = 224
  EarthboundViewportMaxHeight* = 1024
  EarthboundDesktopScale* = 2

proc panelCrop*(x, y, width, height: int): PanelCrop =
  ## Construct one source rectangle in combined-frame coordinates.
  (x, y, width, height)

proc contains*(crop: PanelCrop, x, y: int): bool =
  ## Report whether a combined-frame pixel lies inside this panel.
  x >= crop.x and y >= crop.y and x < crop.x + crop.width and y < crop.y + crop.height

proc stackedGeometry*(panelWidth, panelHeight: int): DualGeometry =
  ## Build two equal full-width panels stacked without inset padding.
  result.frameWidth = panelWidth
  result.frameHeight = panelHeight * 2
  result.game = panelCrop(0, 0, panelWidth, panelHeight)
  result.companion = panelCrop(0, panelHeight, panelWidth, panelHeight)

proc earthboundGeometry*(viewportWidth, viewportHeight: int): DualGeometry =
  ## Place the outdoor game panel above a centered 256x224 companion.
  if viewportWidth < EarthboundViewportMinWidth or viewportWidth > EarthboundViewportMaxWidth or
      viewportHeight < EarthboundViewportMinHeight or viewportHeight > EarthboundViewportMaxHeight:
    raise newException(ValueError,
      "--earthbound-viewport width must be 256..1024 and height 224..1024")
  result.frameWidth = viewportWidth
  result.frameHeight = viewportHeight + EarthboundCompanionHeight
  result.game = panelCrop(0, 0, viewportWidth, viewportHeight)
  result.companion = panelCrop((viewportWidth - EarthboundCompanionWidth) div 2,
    viewportHeight, EarthboundCompanionWidth, EarthboundCompanionHeight)

proc dualCrops*(geometry: DualGeometry): array[2, PanelCrop] =
  ## Return the explicit game and companion rectangles in output order.
  [geometry.game, geometry.companion]

proc inPadding*(geometry: DualGeometry, x, y: int): bool =
  ## True for combined-frame pixels that are neither game nor companion.
  x >= 0 and y >= 0 and x < geometry.frameWidth and y < geometry.frameHeight and
    not geometry.game.contains(x, y) and not geometry.companion.contains(x, y)

proc validateDualGeometry*(width, height: int, geometry: DualGeometry) =
  ## Require a software frame that matches the explicit dual-screen crops.
  if geometry.frameWidth <= 0 or geometry.frameHeight <= 0 or
      geometry.game.width <= 0 or geometry.game.height <= 0 or
      geometry.companion.width <= 0 or geometry.companion.height <= 0:
    raise newException(ValueError, "Dual-screen crops must be positive")
  if width != geometry.frameWidth or height != geometry.frameHeight:
    raise newException(ValueError, "DS mode requires a " & $geometry.frameWidth & "x" &
      $geometry.frameHeight & " software frame")
  let
    game = geometry.game
    companion = geometry.companion
  if game.x < 0 or game.y < 0 or companion.x < 0 or companion.y < 0 or
      game.x + game.width > geometry.frameWidth or
      game.y + game.height > geometry.frameHeight or
      companion.x + companion.width > geometry.frameWidth or
      companion.y + companion.height > geometry.frameHeight:
    raise newException(ValueError, "Dual-screen crops must fit inside the software frame")

proc parseEarthboundViewport*(value: string): tuple[width, height: int] =
  ## Parse WIDTHxHEIGHT for the outdoor game panel.
  let parts = value.split('x')
  if parts.len != 2 or parts.anyIt(it.len == 0 or not it.allCharsInSet({'0'..'9'})):
    raise newException(ValueError, "--earthbound-viewport must be WIDTHxHEIGHT")
  try:
    result.width = parseInt(parts[0])
    result.height = parseInt(parts[1])
  except ValueError:
    raise newException(ValueError, "--earthbound-viewport must be WIDTHxHEIGHT")
  discard earthboundGeometry(result.width, result.height)

proc parseEarthboundScale*(value: string): tuple[autoScale: bool, scale: int] =
  ## Parse auto or a positive integer scale for the game desktop window.
  if value == "auto":
    return (true, EarthboundDesktopScale)
  if value.len == 0 or not value.allCharsInSet({'0'..'9'}):
    raise newException(ValueError, "--earthbound-scale must be auto or a positive integer")
  try:
    result.scale = parseInt(value)
  except ValueError:
    raise newException(ValueError, "--earthbound-scale must be auto or a positive integer")
  if result.scale <= 0 or result.scale > high(int32).int div EarthboundViewportMaxWidth:
    raise newException(ValueError, "--earthbound-scale must be auto or a positive integer")
  result.autoScale = false

proc desktopWindowSizes*(game: PanelCrop, companion: PanelCrop, gameScale, companionScale: int):
    array[2, tuple[width, height: int]] =
  ## Initial desktop sizes for the game and companion windows.
  if gameScale <= 0 or companionScale <= 0:
    raise newException(ValueError, "Desktop window scales must be positive")
  result[0] = (game.width * gameScale, game.height * gameScale)
  result[1] = (companion.width * companionScale, companion.height * companionScale)

proc visibleCrop*(separate: bool, index: int, geometry: DualGeometry): PanelCrop =
  ## Select the source rectangle shown by one combined or split output.
  if not separate:
    return panelCrop(0, 0, geometry.frameWidth, geometry.frameHeight)
  if index == 0: geometry.game else: geometry.companion
