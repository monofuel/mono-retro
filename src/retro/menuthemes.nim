import
  std/[json, os],
  ./launcherui

type
  MenuTheme* = enum
    LibraryTheme, ShowcaseTheme, PocketTheme, WorkbenchTheme
  ThemePalette* = object
    background*, surface*, selected*, accent*, text*, muted*: uint32
  ThemeLayout* = object
    cards*: seq[UiRect]
    columns*, first*: int
    hero*, play*, tools*, previous*, next*: UiRect

const
  ThemeNames*: array[MenuTheme, string] = ["Library", "Showcase", "Pocket", "Workbench"]
  ThemeKeys*: array[MenuTheme, string] = ["library", "showcase", "pocket", "workbench"]
  ThemeDescriptions*: array[MenuTheme, string] = ["Covers, filters and your collection.",
    "One game in the spotlight.", "Bright cards for a pocket-sized library.",
    "Hardware tools and device status first."]
  ThemePalettes*: array[MenuTheme, ThemePalette] = [
    ThemePalette(background: 0x0b1220, surface: 0x162338, selected: 0x286c76,
      accent: 0x72dfc3, text: 0xeaf0f7, muted: 0x9eafc2),
    ThemePalette(background: 0x181423, surface: 0x29213a, selected: 0x58416b,
      accent: 0xf4c78b, text: 0xfff3e2, muted: 0xc0adc8),
    ThemePalette(background: 0xf2edda, surface: 0xfffbef, selected: 0xc9e8d4,
      accent: 0x176c61, text: 0x243f46, muted: 0x546a71),
    ThemePalette(background: 0x111923, surface: 0x202e3e, selected: 0x285e9e,
      accent: 0x67c7ae, text: 0xeaf0f7, muted: 0x9eafc2)]
  CardMargin = 16

proc parseTheme*(key: string): MenuTheme =
  ## Accept stable theme identifiers in preferences and command-line overrides.
  for theme in MenuTheme:
    if ThemeKeys[theme] == key: return theme
  raise newException(ValueError, "Unknown menu theme: " & key)

proc themePreferencesPath*(): string =
  ## Keep appearance on this OS, independent of the removable games card.
  getConfigDir() / "mono-retro" / "menu.json"

proc loadTheme*(path: string): MenuTheme =
  ## Preserve the existing library appearance when preferences do not exist.
  if not fileExists(path): return LibraryTheme
  parseTheme(parseFile(path)["theme"].getStr())

proc saveTheme*(path: string, theme: MenuTheme) =
  ## Publish the applied choice atomically without rewriting library configuration.
  createDir(path.parentDir)
  writeFile(path & ".tmp", $(%*{"theme": ThemeKeys[theme]}) & "\n")
  moveFile(path & ".tmp", path)

proc themeLayout*(theme: MenuTheme, width, height, selected, count: int): ThemeLayout =
  ## Define cover geometry once for painting, pointer targets and navigation.
  result.play = UiRect(x: CardMargin, y: height - 60,
    width: width div 2 - 24, height: 38)
  result.tools = UiRect(x: width div 2 + 8, y: height - 60,
    width: width div 2 - 24, height: 38)
  result.previous = UiRect(x: 0, y: 64, width: width div 2, height: 36)
  result.next = UiRect(x: width div 2, y: 64, width: width div 2, height: 36)
  if theme == ShowcaseTheme:
    result.columns = 1
    result.hero = UiRect(x: CardMargin, y: 108,
      width: width - CardMargin * 2, height: max(1, (height - 188) * 2 div 3))
    let
      visible = min(count, max(1, width div 110))
      cardWidth = (width - CardMargin * 2 - max(0, visible - 1) * 8) div max(1, visible)
      top = result.hero.y + result.hero.height + 8
    result.first = clamp(selected - visible div 2, 0, max(0, count - visible))
    for position in 0 ..< visible:
      result.cards.add UiRect(x: CardMargin + position * (cardWidth + 8),
        y: top, width: cardWidth, height: max(1, result.play.y - top - 8))
  else:
    result.columns = clamp(width div (if theme == PocketTheme: 230 else: 190), 1, 5)
    let
      rows = if height < 390: 1 else: 2
      pageSize = result.columns * rows
      cardWidth = (width - CardMargin * (result.columns + 1)) div result.columns
      cardHeight = max(36, (height - 182 - (rows - 1) * 8) div rows)
    result.first = max(0, selected) div pageSize * pageSize
    for index in result.first ..< min(count, result.first + pageSize):
      let position = index - result.first
      result.cards.add UiRect(x: CardMargin + (position mod result.columns) * (cardWidth + CardMargin),
        y: 104 + (position div result.columns) * (cardHeight + 8),
        width: cardWidth, height: cardHeight)
