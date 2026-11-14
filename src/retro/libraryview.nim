import
  std/[algorithm, os, strutils, tables, unicode, wordwrap],
  pixie,
  ./[gamelibrary, launcherui, pattern, systeminfo]

type
  LibraryPage* = enum
    GamesPage, ToolsPage, CollectionsPage, GamePage, SystemPage, PairPage, PowerPage, ConflictPage
  LibraryViewState* = object
    page*: LibraryPage
    selected*, tool*, collection*, filter*, scroll*: int
    message*: string
    busy*, error*, confirmYes*, reboot*: bool
    transition*: float32
  LibraryUi* = ref object
    text: LauncherUi
    covers: Table[string, Image]
  LibraryLayout* = object
    cards*: seq[UiRect]
    columns*, first*: int
    play*, tools*, previous*, next*: UiRect

const
  Background = 0x0b1220'u32
  Surface = 0x162338'u32
  Selected = 0x286c76'u32
  Accent = 0x72dfc3'u32
  Muted = 0x9eafc2'u32
  CardMargin = 16
  MaximumCovers = 24
  CoverWidth = 180
  CoverHeight = 240
  MaximumCoverPixels = 4_000_000
  ToolLabels* = ["Hardware Test", "System Info", "RomM collections", "Connect to RomM",
    "Sync now", "Disconnect RomM", "Reboot", "Shut down", "Rescan games"]

proc newLibraryUi*(): LibraryUi =
  ## Reuse the launcher's embedded font and keep artwork memory bounded.
  LibraryUi(text: newLauncherUi())

proc clearCovers*(ui: LibraryUi) =
  ## Reload thumbnail bytes after a completed artwork update.
  ui.covers.clear()

proc shortText(text: string, length: int): string =
  ## Truncate labels at Unicode character boundaries.
  let characters = text.toRunes()
  if characters.len <= length: text else: $characters[0 ..< max(0, length - 1)] & "…"

proc filters*(index: LibraryIndex): seq[string] =
  ## Keep navigation filters stable across scans and metadata updates.
  result = @["All", "Recent", "Favourites"]
  for game in index.games:
    let label = game.platform.toUpperAscii()
    if label notin result: result.add label
  if result.len > 3: result[3 .. ^1] = result[3 .. ^1].sorted()

proc visibleGames*(index: LibraryIndex, filter: int): seq[LibraryGame] =
  ## Return shared game identities in the current view's presentation order.
  let choices = index.filters()
  let selected = choices[clamp(filter, 0, choices.high)]
  for game in index.games:
    if selected == "Favourites" and not game.favourite: continue
    if selected == "Recent" and game.lastPlayed == 0: continue
    if filter >= 3 and game.platform.toUpperAscii() != selected: continue
    result.add game
  if selected == "Recent":
    result.sort(proc(a, b: LibraryGame): int = cmp(b.lastPlayed, a.lastPlayed))

proc libraryLayout*(width, height, selected, count: int): LibraryLayout =
  ## Share responsive card rectangles between touch handling and rendering.
  result.columns = clamp(width div 190, 1, 5)
  let
    rows = if height < 390: 1 else: 2
    pageSize = result.columns * rows
    cardWidth = (width - CardMargin * (result.columns + 1)) div result.columns
    cardHeight = max(36, (height - 182 - (rows - 1) * 8) div rows)
  result.first = max(0, selected) div pageSize * pageSize
  for index in result.first ..< min(count, result.first + pageSize):
    let position = index - result.first
    result.cards.add UiRect(x: CardMargin + (position mod result.columns) * (cardWidth + CardMargin),
      y: 104 + (position div result.columns) * (cardHeight + 8), width: cardWidth, height: cardHeight)
  result.play = UiRect(x: CardMargin, y: height - 60, width: width div 2 - 24, height: 38)
  result.tools = UiRect(x: width div 2 + 8, y: height - 60, width: width div 2 - 24, height: 38)
  result.previous = UiRect(x: 0, y: 64, width: width div 2, height: 36)
  result.next = UiRect(x: width div 2, y: 64, width: width div 2, height: 36)

proc cover(ui: LibraryUi, paths: LibraryPaths, game: LibraryGame): Image =
  ## Decode each cover once and cap the thumbnail cache on one-GiB devices.
  if game.cover.len == 0: return
  let path = paths.root.inside(game.cover)
  if not fileExists(path): return
  if path notin ui.covers:
    if ui.covers.len >= MaximumCovers: ui.covers.clear()
    ui.covers[path] = nil
    try:
      let dimensions = readImageDimensions(path)
      if dimensions.width.int64 * dimensions.height.int64 > MaximumCoverPixels: return
      let original = readImage(path)
      let scale = min(CoverWidth.float32 / original.width.float32,
        CoverHeight.float32 / original.height.float32)
      ui.covers[path] = original.resize(max(1, int(original.width.float32 * scale)),
        max(1, int(original.height.float32 * scale)))
    except PixieError:
      return
  ui.covers[path]

proc drawCover(ui: LibraryUi, image: Image, paths: LibraryPaths,
    game: LibraryGame, area: UiRect) =
  ## Fit artwork without stretching; local games retain a readable placeholder.
  let cover = ui.cover(paths, game)
  if cover == nil:
    image.rect(area.x, area.y, area.width, area.height, Background)
    ui.text.label(image, game.platform.toUpperAscii(), area.x + 12, area.y + area.height div 2 - 10, 22, Accent)
  else:
    let scale = min(area.width.float32 / cover.width.float32, area.height.float32 / cover.height.float32)
    image.draw(cover, translate(vec2(area.x.float32 + (area.width.float32 - cover.width.float32 * scale) / 2,
      area.y.float32 + (area.height.float32 - cover.height.float32 * scale) / 2)) * scale(vec2(scale)))

proc renderLibrary*(ui: LibraryUi, paths: LibraryPaths, index: LibraryIndex,
    state: LibraryViewState, power: PowerStatus, width, height: int,
    detailsScreen: bool, systemLines: seq[string]): Image =
  ## Render the library and its settings through the existing Pixie display path.
  result = newCanvas(width, height)
  result.fill(Background)
  ui.text.toolbar(result, "mono-retro", power)
  let
    games = index.visibleGames(state.filter)
    layout = libraryLayout(width, height, state.selected, games.len)
    game = if games.len > 0: games[clamp(state.selected, 0, games.high)] else: nil
  if detailsScreen or state.page == GamePage:
    if game != nil:
      ui.drawCover(result, paths, game, UiRect(x: 28, y: 90,
        width: max(80, width div 3), height: height - 180))
      let left = width div 3 + 60
      ui.text.label(result, shortText(game.title, max(10, (width - left) div 13)), left, 104, 25)
      ui.text.label(result, game.platform.toUpperAscii() & "  ·  " & game.core, left, 150, 18, Accent)
      ui.text.label(result, if game.favourite: "Favourite" else: "Y: Add favourite", left, 188, 18, Muted)
      var y = 232
      for line in game.summary.splitLines():
        for segment in line.wrapWords(max(15, (width - left) div 10)).splitLines():
          if y < height - 90:
            ui.text.label(result, segment, left, y, 17, Muted)
            y += 24
      if state.page == GamePage:
        ui.text.label(result, "A / Enter: Play     B: Back", 28, height - 45, 18, Accent)
    else:
      ui.text.label(result, "Your next game awaits", 32, height div 2, 27, Accent)
      ui.text.label(result, "Add games locally or choose a RomM collection.", 32, height div 2 + 45, 18, Muted)
  elif state.page == GamesPage:
    let choices = index.filters()
    ui.text.label(result, "‹  " & choices[clamp(state.filter, 0, choices.high)] & "  ›", 24, 75, 20, Accent)
    ui.text.label(result, $games.len & " games", max(24, width - 125), 77, 17, Muted)
    for position, area in layout.cards:
      let
        index = layout.first + position
        item = games[index]
        active = index == state.selected
      result.rect(area.x, area.y, area.width, area.height, if active: Selected else: Surface)
      if active:
        result.rect(area.x, area.y + area.height - 3,
          max(1, int(area.width.float32 * state.transition)), 3, Accent)
      ui.drawCover(result, paths, item, UiRect(x: area.x + 7, y: area.y + 7,
        width: area.width - 14, height: max(20, area.height - 43)))
      ui.text.label(result, shortText(item.title, max(5, (area.width - 12) div 9)),
        area.x + 7, area.y + area.height - 28, 16)
      if item.favourite: ui.text.label(result, "★", area.x + area.width - 27, area.y + 10, 20, Accent)
    for area in [layout.play, layout.tools]: result.rect(area.x, area.y, area.width, area.height, Surface)
    ui.text.label(result, if state.busy: "Working…" elif width < 500: "A: Play" else:
      "A: Play    X: Details", layout.play.x + 12, layout.play.y + 9, 17, Accent)
    ui.text.label(result, if width < 500: "Start: Menu" else:
      "Start: Menu    Y: Favourite", layout.tools.x + 12, layout.tools.y + 9, 16, Muted)
    if games.len == 0: ui.text.label(result, "No games in this view", 28, height div 2, 22, Muted)
  elif state.page in {ToolsPage, CollectionsPage}:
    let count = if state.page == ToolsPage: ToolLabels.len else: index.collections.len
    let selection = if state.page == ToolsPage: state.tool else: state.collection
    let rows = max(1, (height - 150) div 43)
    let first = max(0, selection - rows + 1)
    ui.text.label(result, if state.page == ToolsPage: "Menu" else: "RomM collections · A toggles", 24, 80, 23, Accent)
    for item in first ..< min(count, first + rows):
      let
        y = 115 + (item - first) * 43
        text = if state.page == ToolsPage: ToolLabels[item] else:
          (if index.collections[item].selected: "✓ " else: "○ ") & index.collections[item].name
      result.rect(16, y, width - 32, 38, if item == selection: Selected else: Surface)
      ui.text.label(result, shortText(text, max(10, (width - 60) div 11)), 30, y + 8, 20)
    if count == 0:
      ui.text.label(result, "Create a collection in RomM, then Sync now.", 28, 150, 19, Muted)
  elif state.page == SystemPage:
    var y = 86
    for line in systemLines[max(0, min(state.scroll, systemLines.len)) ..< systemLines.len]:
      if y < height - 80: ui.text.label(result, shortText(line, max(10, (width - 48) div 10)), 24, y, 17, Muted)
      y += 25
  elif state.page == PairPage:
    ui.text.label(result, "Connect to RomM", 24, 92, 28, Accent)
    var y = 152
    for line in state.message.splitLines():
      for wrapped in line.wrapWords(max(20, (width - 48) div 12)).splitLines():
        ui.text.label(result, wrapped, 24, y, 22)
        y += 36
    ui.text.label(result, "Approve in your browser. B cancels.", 24, height - 74, 18, Muted)
  elif state.page == PowerPage:
    ui.text.label(result, if state.reboot: "Reboot this device?" else: "Shut down this device?", 24, 110, 28)
    ui.text.label(result, if state.confirmYes: "Cancel     [ Confirm ]" else: "[ Cancel ]     Confirm", 24, 190, 24, Accent)
  elif state.page == ConflictPage:
    ui.text.label(result, "Two versions of your save", 24, 110, 28, Accent)
    ui.text.label(result, "Both versions will be preserved.", 24, 158, 20, Muted)
    ui.text.label(result, if state.confirmYes: "Local save     [ RomM save ]" else:
      "[ Local save ]     RomM save", 24, 220, 23)
    ui.text.label(result, "Choose with Left/Right, then A. B cancels.", 24, 280, 18, Muted)
  if state.message.len > 0 and state.page != PairPage:
    ui.text.label(result, shortText(state.message.splitLines()[0], max(10, (width - 32) div 8)),
      16, height - 20, 14, if state.error: 0xffa08e'u32 else: Muted)
