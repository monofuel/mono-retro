type
  MenuAction* = enum
    NoAction, LaunchTester, QuitLauncher, RebootSystem, ShutdownSystem
  MenuState* = object
    selected*: int
    info*: bool
    scroll*: int
    error*: string
    armed*: bool
    confirmation*: MenuAction
    confirmYes*, busy*: bool
  MenuInput* = enum
    Previous, Next, Open, Back

const
  MenuLabels* = ["Hardware Test", "System Info", "Reboot", "Shut Down"]
  ScrollStep* = 48

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
    else: state.selected = clamp(state.selected + direction, 0, MenuLabels.high)
  of Back:
    if state.info:
      state.info = false
      state.scroll = 0
    elif desktop: return QuitLauncher
  of Open:
    if not state.armed or state.info: return NoAction
    case state.selected
    of 0: return LaunchTester
    of 1:
      state.info = true
      state.scroll = 0
    else:
      state.confirmation = if state.selected == 2: RebootSystem else: ShutdownSystem
      state.confirmYes = false
      state.armed = false
      state.error = ""
