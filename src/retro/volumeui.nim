## Compact shared rendering for the system-volume toast.

import
  std/[math, unicode],
  pixie,
  ./pattern

const
  FontBytes = staticRead("../../assets/Roboto-Regular.ttf")
  Background = 0x111923'u32
  Panel = 0x202E3E'u32
  Accent = 0x67C7AE'u32
  Muted = 0x9EAFC2'u32
  Error = 0xE79A76'u32

type
  VolumeUi* = ref object
    font: Font

proc newVolumeUi*(): VolumeUi =
  ## Parse the shared overlay font once for compact volume-toast drawing.
  VolumeUi(font: newFont(parseTtf(FontBytes)))

proc paint(ui: VolumeUi, image: Image, text: string, x, y: int,
    size: float32, tint: uint32, width = 0) =
  ## Draw bounded, opaque text with the overlay's existing color language.
  ui.font.size = size
  ui.font.paint.color = color(float32(tint shr 16 and 255) / 255,
    float32(tint shr 8 and 255) / 255, float32(tint and 255) / 255, 1)
  image.fillText(ui.font.typeset(text, bounds = vec2(width.float32, 0)),
    translate(vec2(x.float32, y.float32)))

proc oneLine(ui: VolumeUi, text: string, size: float32, width: int): string =
  ## Ellipsize diagnostics so a toast remains compact at narrow game widths.
  ui.font.size = size
  if ui.font.typeset(text).layoutBounds().x <= width.float32:
    return text
  var characters = text.toRunes()
  while characters.len > 0:
    characters.setLen(characters.len - 1)
    result = $characters & "…"
    if ui.font.typeset(result).layoutBounds().x <= width.float32:
      return

proc renderVolume*(ui: VolumeUi, percent: int, error: string, width: int,
    previous: Image = nil): Image =
  ## Render a small opaque blue-teal volume bar, percentage, and optional error.
  if width <= 0:
    raise newException(ValueError, "Volume toast width must be positive")
  let
    factor = clamp(width.float32 / 256, 0.5'f32, 2'f32)
    height = max(28, int((if error.len == 0: 42 else: 60) * factor))
    margin = max(4, int(8 * factor))
    icon = max(10, int(16 * factor))
    barX = margin + icon + margin
    barWidth = max(8, width - barX - margin)
    barY = margin + max(2, int(4 * factor))
    barHeight = max(5, int(8 * factor))
    clamped = clamp(percent, 0, 100)
  result = previous
  if result == nil or result.width != width or result.height != height:
    result = newImage(width, height)
  result.fill(Background)
  result.rect(margin, barY + 2, icon div 3, icon - 4,
    if clamped == 0: Muted else: Accent)
  result.rect(margin + icon div 3, barY, icon div 2, icon,
    if clamped == 0: Muted else: Accent)
  result.rect(barX, barY, barWidth, barHeight, Panel)
  if error.len == 0:
    result.rect(barX, barY, barWidth * clamped div 100, barHeight, Accent)
  ui.paint(result, if error.len == 0: "Volume " & $clamped & "%" else: "Volume unavailable",
    barX, barY + barHeight + max(10, int(13 * factor)),
    10 * factor, Muted, barWidth)
  if error.len > 0:
    ui.paint(result, ui.oneLine(error, 9 * factor, width - margin * 2), margin,
      height - margin - max(4, int(10 * factor)), 9 * factor, Error, width - margin * 2)
