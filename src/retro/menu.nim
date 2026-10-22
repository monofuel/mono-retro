type
  MenuAction* = enum
    NoAction, LaunchTester, QuitLauncher
  MenuState* = object
    selected*: int
    info*: bool
    scroll*: int
    error*: string
    armed*: bool
  MenuInput* = enum
    Previous, Next, Open, Back

const
  MenuLabels* = ["Hardware Test", "System Info"]
  ScrollStep* = 48

proc handle*(state: var MenuState, input: MenuInput, desktop: bool): MenuAction =
  ## Keep navigation independent from drawing and device input APIs.
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
    if state.selected == 0: return LaunchTester
    state.info = true
    state.scroll = 0
