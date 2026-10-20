import
  std/[strutils]

type
  Color* = uint32
  Canvas* = object
    width*, height*: int
    pixels*: seq[Color]

const
  White* = 0xffffff'u32
  Black* = 0x000000'u32
  Background* = 0x101820'u32
  Cyan* = 0x30d8e0'u32
  Green* = 0x30d870'u32
  Gray* = 0x303c48'u32
  Glyphs = [
    ('A', "01110 10001 10001 11111 10001 10001 10001"),
    ('B', "11110 10001 10001 11110 10001 10001 11110"),
    ('C', "01111 10000 10000 10000 10000 10000 01111"),
    ('D', "11110 10001 10001 10001 10001 10001 11110"),
    ('E', "11111 10000 10000 11110 10000 10000 11111"),
    ('F', "11111 10000 10000 11110 10000 10000 10000"),
    ('G', "01111 10000 10000 10111 10001 10001 01111"),
    ('H', "10001 10001 10001 11111 10001 10001 10001"),
    ('I', "11111 00100 00100 00100 00100 00100 11111"),
    ('J', "00111 00010 00010 00010 10010 10010 01100"),
    ('K', "10001 10010 10100 11000 10100 10010 10001"),
    ('L', "10000 10000 10000 10000 10000 10000 11111"),
    ('M', "10001 11011 10101 10101 10001 10001 10001"),
    ('N', "10001 11001 10101 10011 10001 10001 10001"),
    ('O', "01110 10001 10001 10001 10001 10001 01110"),
    ('P', "11110 10001 10001 11110 10000 10000 10000"),
    ('Q', "01110 10001 10001 10001 10101 10010 01101"),
    ('R', "11110 10001 10001 11110 10100 10010 10001"),
    ('S', "01111 10000 10000 01110 00001 00001 11110"),
    ('T', "11111 00100 00100 00100 00100 00100 00100"),
    ('U', "10001 10001 10001 10001 10001 10001 01110"),
    ('V', "10001 10001 10001 10001 10001 01010 00100"),
    ('W', "10001 10001 10001 10101 10101 10101 01010"),
    ('X', "10001 10001 01010 00100 01010 10001 10001"),
    ('Y', "10001 10001 01010 00100 00100 00100 00100"),
    ('Z', "11111 00001 00010 00100 01000 10000 11111"),
    ('0', "01110 10001 10011 10101 11001 10001 01110"),
    ('1', "00100 01100 00100 00100 00100 00100 01110"),
    ('2', "01110 10001 00001 00010 00100 01000 11111"),
    ('3', "11110 00001 00001 01110 00001 00001 11110"),
    ('4', "00010 00110 01010 10010 11111 00010 00010"),
    ('5', "11111 10000 10000 11110 00001 00001 11110"),
    ('6', "01110 10000 10000 11110 10001 10001 01110"),
    ('7', "11111 00001 00010 00100 01000 01000 01000"),
    ('8', "01110 10001 10001 01110 10001 10001 01110"),
    ('9', "01110 10001 10001 01111 00001 00001 01110"),
    ('-', "00000 00000 00000 11111 00000 00000 00000"),
    (':', "00000 00100 00100 00000 00100 00100 00000"),
    ('/', "00001 00010 00010 00100 01000 01000 10000"),
    ('.', "00000 00000 00000 00000 00000 00100 00100"),
    ('+', "00000 00100 00100 11111 00100 00100 00000")
  ]

proc newCanvas*(width, height: int): Canvas =
  if width <= 0 or height <= 0 or width > 8192 or height > 8192:
    raise newException(ValueError, "Invalid canvas dimensions")
  Canvas(width: width, height: height, pixels: newSeq[Color](width * height))

proc fill*(canvas: var Canvas, color: Color) =
  for pixel in canvas.pixels.mitems:
    pixel = color

proc rect*(canvas: var Canvas, x, y, width, height: int, color: Color) =
  for row in max(0, y) ..< min(canvas.height, y + height):
    for column in max(0, x) ..< min(canvas.width, x + width):
      canvas.pixels[row * canvas.width + column] = color

proc text*(canvas: var Canvas, x, y: int, value: string, color = White, scale = 2) =
  for index, character in value.toUpperAscii():
    for (letter, bitmap) in Glyphs:
      if character == letter:
        for row in 0 ..< 7:
          for column in 0 ..< 5:
            if bitmap[row * 6 + column] == '1':
              canvas.rect(x + (index * 6 + column) * scale, y + row * scale,
                scale, scale, color)
        break

proc testPattern*(width, height, tick: int): Canvas =
  const Colors = [White, 0xffff00'u32, Cyan, Green, 0xff00ff'u32, 0xff3030'u32, 0x3030ff'u32, Black]
  result = newCanvas(width, height)
  result.fill(Background)
  let bandHeight = max(20, height div 5)
  for index, color in Colors:
    let
      left = index * width div Colors.len
      right = (index + 1) * width div Colors.len
    result.rect(left, 0, right - left, bandHeight, color)
  for column in 0 ..< width:
    let gray = uint32(column * 255 div max(1, width - 1))
    result.rect(column, height - 24, 1, 16, gray * 0x010101'u32)
  result.rect(0, 0, width, 2, White)
  result.rect(0, height - 2, width, 2, White)
  result.rect(0, 0, 2, height, White)
  result.rect(width - 2, 0, 2, height, White)
  result.rect(4 + (tick mod max(1, width - 20)), height - 6, 12, 4, Cyan)

proc rotatedPoint*(x, y, width, height, rotation: int): tuple[x, y: int] =
  case rotation
  of 0: (x, y)
  of 90: (height - 1 - y, x)
  of 180: (width - 1 - x, height - 1 - y)
  of 270: (y, width - 1 - x)
  else: raise newException(ValueError, "Rotation must be 0, 90, 180 or 270")

proc savePpm*(canvas: Canvas, path: string) =
  var output = "P6\n" & $canvas.width & " " & $canvas.height & "\n255\n"
  for pixel in canvas.pixels:
    output.add char((pixel shr 16) and 255)
    output.add char((pixel shr 8) and 255)
    output.add char(pixel and 255)
  writeFile(path, output)
