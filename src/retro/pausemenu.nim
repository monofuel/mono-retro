import
  std/[os, times],
  pixie,
  ./[overlayui, pattern, playerslots]

type
  PausePage* = enum
    PauseRoot, PauseSave, PauseLoad, PauseRecent, PauseConfirm, PauseAchievements
  PauseRequestKind* = enum
    PauseNothing, PauseSaveSlot, PauseLoadState, PauseExit
  PauseRequest* = object
    kind*: PauseRequestKind
    slot*: int
    path*: string
  PauseMenu* = ref object
    store: StateStore
    page*, returnPage: PausePage
    selected*, first: int
    entries*: seq[StateEntry]
    message*: string
    supported, canImport: bool
    confirmYes: bool
    target: StateEntry
    request: PauseRequest
    thumbnails: seq[tuple[path: string, image: Image]]

const
  RootLabels = ["Resume", "Save State", "Load State", "Achievements", "Exit to Launcher"]
  PageRows = 4
  RowTop = 88
  RowHeight = 52
  RowStride = 56
  Background = 0x111923'u32
  Panel = 0x202E3E'u32
  Highlight = 0x285E9E'u32
  Text = 0xEAF0F7'u32
  Muted = 0x9EAFC2'u32

proc newPauseMenu*(store: StateStore, supported, canImport: bool): PauseMenu =
  ## Create game-local navigation independently of window and core ownership.
  PauseMenu(store: store, supported: supported, canImport: canImport)

proc openRoot*(menu: PauseMenu) =
  ## Return to the pause menu without carrying a pending confirmation.
  menu.page = PauseRoot
  menu.selected = 0
  menu.first = 0
  menu.message = ""
  menu.request = PauseRequest()
  menu.thumbnails.setLen(0)

proc refresh(menu: PauseMenu) =
  ## Refresh slot metadata or resumable captures while emulation is paused.
  menu.entries = if menu.page == PauseRecent: menu.store.recent() else: menu.store.slots()
  menu.selected = clamp(menu.selected, 0, max(0, menu.entries.high))
  menu.first = menu.selected div PageRows * PageRows
  menu.thumbnails.setLen(0)

proc takeRequest*(menu: PauseMenu): PauseRequest =
  ## Consume one confirmed storage or exit operation.
  result = menu.request
  menu.request = PauseRequest()

proc complete*(menu: PauseMenu, message: string) =
  ## Keep storage results visible and refresh thumbnails after successful writes.
  menu.page = menu.returnPage
  menu.message = message
  menu.refresh()

proc selectEntry(menu: PauseMenu) =
  ## Ask before replacing a slot or restoring a machine state.
  if menu.selected notin 0 ..< menu.entries.len: return
  let entry = menu.entries[menu.selected]
  if menu.page == PauseSave:
    if not menu.supported:
      menu.message = "This core cannot save states."
    elif not fileExists(entry.path):
      menu.returnPage = menu.page
      menu.request = PauseRequest(kind: PauseSaveSlot, slot: entry.slot)
    else:
      menu.target = entry
      menu.returnPage = menu.page
      menu.page = PauseConfirm
      menu.confirmYes = false
  elif not menu.canImport:
    menu.message = "This core cannot load states."
  elif entry.unavailable.len > 0:
    menu.message = entry.unavailable
  elif not fileExists(entry.path):
    menu.message = "This slot is empty."
  else:
    menu.target = entry
    menu.returnPage = menu.page
    menu.page = PauseConfirm
    menu.confirmYes = false

proc handle*(menu: PauseMenu, command: OverlayControl): bool =
  ## Apply navigation and report whether the caller should resume gameplay.
  menu.message = ""
  if command == OcResume:
    if menu.page == PauseRoot: return true
    if menu.page == PauseConfirm: menu.page = menu.returnPage
    else: menu.openRoot()
    return false
  case menu.page
  of PauseRoot:
    case command
    of OcPrevious: menu.selected = max(0, menu.selected - 1)
    of OcNext: menu.selected = min(RootLabels.high, menu.selected + 1)
    of OcActivate:
      case menu.selected
      of 0: return true
      of 1, 2:
        if menu.selected == 1 and not menu.supported:
          menu.message = "This core cannot save states."
        elif menu.selected == 2 and not menu.canImport:
          menu.message = "This core cannot load states."
        else:
          menu.page = if menu.selected == 1: PauseSave else: PauseLoad
          menu.selected = 0
          menu.refresh()
      of 3: menu.page = PauseAchievements
      of 4: menu.request = PauseRequest(kind: PauseExit)
      else: discard
    else: discard
  of PauseConfirm:
    case command
    of OcPrevious, OcNext: menu.confirmYes = not menu.confirmYes
    of OcActivate:
      if menu.confirmYes:
        menu.request = if menu.returnPage == PauseSave:
            PauseRequest(kind: PauseSaveSlot, slot: menu.target.slot)
          else: PauseRequest(kind: PauseLoadState, path: menu.target.path)
      else: menu.page = menu.returnPage
    else: discard
  of PauseSave, PauseLoad, PauseRecent:
    case command
    of OcPrevious: menu.selected = max(0, menu.selected - 1)
    of OcNext: menu.selected = min(max(0, menu.entries.high), menu.selected + 1)
    of OcActivate: menu.selectEntry()
    else: discard
    menu.first = menu.selected div PageRows * PageRows
    if menu.thumbnails.len > PageRows + 1: menu.thumbnails.setLen(0)
  of PauseAchievements: discard

proc switchSource*(menu: PauseMenu) =
  ## Switch between numbered slots and recent captures in the load browser.
  if menu.page notin {PauseLoad, PauseRecent}: return
  menu.page = if menu.page == PauseLoad: PauseRecent else: PauseLoad
  menu.selected = 0
  menu.refresh()

proc pageBy*(menu: PauseMenu, direction: int) =
  ## Page through slot and capture lists without repeated button presses.
  if menu.page in {PauseLoad, PauseRecent, PauseSave}:
    menu.selected = clamp(menu.selected + direction * PageRows, 0, max(0, menu.entries.high))
    menu.first = menu.selected div PageRows * PageRows
    menu.thumbnails.setLen(0)
  elif menu.page == PauseConfirm:
    menu.confirmYes = not menu.confirmYes

proc entryImage(menu: PauseMenu, entry: StateEntry): Image =
  ## Decode only visible previews and discard them when the page changes.
  if not fileExists(entry.path): return nil
  for item in menu.thumbnails:
    if item.path == entry.path: return item.image
  try:
    result = entry.thumbnail()
  except CatchableError as error:
    menu.message = "Preview unavailable: " & error.msg
  menu.thumbnails.add((entry.path, result))

proc drawPreview(image, preview: Image, x, y, width, height: int) =
  ## Preserve aspect ratio while fitting both screens into an opaque preview.
  image.rect(x, y, width, height, Panel)
  if preview == nil: return
  let
    factor = min(width.float32 / preview.width.float32, height.float32 / preview.height.float32)
    w = max(1, int(preview.width.float32 * factor))
    h = max(1, int(preview.height.float32 * factor))
  image.draw(preview, translate(vec2((x + (width - w) div 2).float32,
    (y + (height - h) div 2).float32)) * scale(vec2(factor, factor)))

proc renderPause*(ui: OverlayUi, menu: PauseMenu, previous: Image = nil): Image =
  ## Draw the pause controls, numbered slots and screenshot confirmation.
  result = previous
  if result == nil or result.width != OverlayPanelWidth or result.height != OverlayPanelHeight:
    result = newImage(OverlayPanelWidth, OverlayPanelHeight)
  result.fill(Background)
  let areas = overlayLayout(0, 0, false)
  if menu.page == PauseRoot:
    ui.paint(result, "Paused", 16, 12, 26)
    for index, label in RootLabels:
      let y = 68 + index * 46
      result.rect(16, y, 480, 40, if index == menu.selected: Highlight else: Panel)
      let disabled = (index == 1 and not menu.supported) or (index == 2 and not menu.canImport)
      ui.paint(result, label & (if disabled: " · unavailable" else: ""), 28, y + 10, 18,
        if disabled: Muted else: Text)
  elif menu.page == PauseConfirm:
    let saving = menu.returnPage == PauseSave
    ui.paint(result, if saving: "Replace this save?" else: "Load this state?", 16, 12, 24)
    ui.paint(result, menu.target.title, 16, 45, 17)
    ui.paint(result, menu.target.timestamp.local.format("yyyy-MM-dd HH:mm:ss"), 16, 68, 13, Muted)
    result.drawPreview(menu.entryImage(menu.target), 120, 94, 272, 210)
    result.rect(16, 328, 232, 36, if not menu.confirmYes: Highlight else: Panel)
    result.rect(264, 328, 232, 36, if menu.confirmYes: Highlight else: Panel)
    ui.paint(result, "Cancel", 28, 337, 17)
    ui.paint(result, if saving: "Replace" else: "Load", 276, 337, 17)
  else:
    ui.paint(result, if menu.page == PauseSave: "Save State"
      elif menu.page == PauseRecent: "Load State · Recent Captures" else: "Load State · Slots", 16, 12, 24)
    ui.paint(result, if menu.page == PauseSave: "Choose a slot"
      else: "Left / Right: Slots or Recent Captures", 16, 48, 14, Muted)
    for row in 0 ..< min(PageRows, max(0, menu.entries.len - menu.first)):
      let
        index = menu.first + row
        entry = menu.entries[index]
        y = RowTop + row * RowStride
      result.rect(16, y, 246, RowHeight, if index == menu.selected: Highlight else: Panel)
      result.drawPreview(menu.entryImage(entry), 20, y + 4, 52, 44)
      ui.paint(result, ui.oneLine(entry.title, 15, 178), 80, y + 6, 15)
      ui.paint(result, ui.oneLine(if not fileExists(entry.path): "Empty"
        else: entry.timestamp.local.format("MM-dd HH:mm:ss"),
        11, 178), 80, y + 29, 11, Muted)
    if menu.selected in 0 ..< menu.entries.len:
      let entry = menu.entries[menu.selected]
      result.drawPreview(menu.entryImage(entry), 276, 88, 220, 218)
    elif menu.entries.len == 0:
      ui.paint(result, "No resumable captures found.", 16, 104, 17, Muted)
  if menu.page != PauseConfirm:
    ui.drawButton(result, areas.resume, if menu.page == PauseRoot: "Resume" else: "Back")
    ui.drawButton(result, areas.previous, "Prev")
    ui.drawButton(result, areas.next, "Next")
    ui.drawButton(result, areas.activate, if menu.page == PauseSave: "Save"
      elif menu.page in {PauseLoad, PauseRecent}: "Load" else: "Open")
  if menu.message.len > 0:
    ui.paint(result, ui.oneLine(menu.message, 12, 480), 16, 309, 12)
  ui.paint(result, "MENU / F1: Resume     A / Enter: Select     B / Back / Esc: Back", 16, 370, 10, Muted)

proc pointer*(menu: PauseMenu, x, y: float32): bool =
  ## Apply the same logical hit targets rendered on the touch or mouse output.
  if menu.page == PauseConfirm:
    if y >= 328 and y < 364:
      if x >= 16 and x < 248:
        menu.confirmYes = false
        return menu.handle(OcActivate)
      if x >= 264 and x < 496:
        menu.confirmYes = true
        return menu.handle(OcActivate)
  elif menu.page == PauseRoot:
    for index in 0 ..< RootLabels.len:
      if x >= 16 and x < 496 and y >= (68 + index * 46).float32 and y < (108 + index * 46).float32:
        menu.selected = index
        return menu.handle(OcActivate)
  else:
    if y >= 42 and y < 78:
      menu.switchSource()
    for row in 0 ..< min(PageRows, max(0, menu.entries.len - menu.first)):
      if x >= 16 and x < 262 and y >= (RowTop + row * RowStride).float32 and
          y < (RowTop + row * RowStride + RowHeight).float32:
        menu.selected = menu.first + row
        return false
  let hit = overlayLayout(0, 0, false).hitTest(x, y)
  if hit.control in {OcPrevious, OcNext} and menu.page in {PauseSave, PauseLoad, PauseRecent}:
    menu.pageBy(if hit.control == OcPrevious: -1 else: 1)
  else:
    return menu.handle(hit.control)
