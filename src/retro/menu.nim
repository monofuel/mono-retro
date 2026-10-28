type
  MenuAction* = enum
    NoAction, LaunchTester, QuitLauncher, RebootSystem, ShutdownSystem, LaunchDecompbound,
    LaunchLostInBlue
  MenuState* = object
    selected*: int
    info*: bool
    scroll*: int
    error*: string
    armed*: bool
    confirmation*: MenuAction
    confirmYes*, busy*: bool
    lostInBlue*: bool
  MenuInput* = enum
    Previous, Next, Open, Back

const
  MenuLabels* = ["Decompbound", "Hardware Test", "System Info", "Reboot", "Shut Down"]
  ScrollStep* = 48

proc labels*(state: MenuState): seq[string] =
  ## Include Lost in Blue only when its launcher is installed.
  result = @MenuLabels
  if state.lostInBlue: result.insert("Lost in Blue", 1)

proc entryIndex*(state: MenuState): int =
  ## Resolve optional Lost in Blue to -1 and retain the base menu indices.
  if state.lostInBlue and state.selected == 1: -1
  elif state.lostInBlue and state.selected > 1: state.selected - 1
  else: state.selected

proc handle*(state: var MenuState, input: MenuInput, desktop: bool): MenuAction =
  ## Keep navigation independent from drawing and device input APIs.
  if state.busy: return NoAction
  if state.confirmation != NoAction:
    case input
    of Previous: state.confirmYes = false
    of Next: state.confirmYes = true
    of Back: state.confirmation = NoAction
    of Open:
      if not state.armed: return NoAction
      if state.confirmYes: return state.confirmation
      state.confirmation = NoAction
    return NoAction
  case input
  of Previous, Next:
    let direction = if input == Previous: -1 else: 1
    if state.info: state.scroll = max(0, state.scroll + direction * ScrollStep)
    else: state.selected = clamp(state.selected + direction, 0, state.labels().high)
  of Back:
    if state.info:
      state.info = false
      state.scroll = 0
    elif desktop: return QuitLauncher
  of Open:
    if not state.armed or state.info: return NoAction
    case state.entryIndex()
    of -1: return LaunchLostInBlue
    of 0: return LaunchDecompbound
    of 1: return LaunchTester
    of 2:
      state.info = true
      state.scroll = 0
    else:
      state.confirmation = if state.entryIndex() == 3: RebootSystem else: ShutdownSystem
      state.confirmYes = false
      state.armed = false
      state.error = ""
