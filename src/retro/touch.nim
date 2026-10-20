import
  ./pattern

type
  TouchContact* = object
    id*, x*, y*: int32
    active*: bool
  TouchState* = object
    enabled*, multitouch*: bool
    minimumX*, maximumX*, minimumY*, maximumY*: int32
    slotMinimum*, slot*: int
    pending*: seq[TouchContact]
    contacts*: seq[TouchContact]
    samples*: seq[TouchContact]
  TouchSample* = object
    id*, x*, y*: int
  TouchTrace* = object
    samples*: seq[TouchSample]
    tested*: array[9, bool]

const
  SlotCode* = 47'u16
  PositionXCode* = 53'u16
  PositionYCode* = 54'u16
  TrackingCode* = 57'u16
  TouchCode* = 330'u16
  MaximumTouchSlots* = 32
  MaximumTraceSamples = 2048
  MaximumContactSamples = 256

proc commit*(state: var TouchState) =
  ## Publish a coherent contact report and retain samples between redraws.
  state.contacts = state.pending
  for contact in state.contacts:
    if contact.active:
      state.samples.add contact
  if state.samples.len > MaximumContactSamples:
    state.samples = state.samples[^MaximumContactSamples .. ^1]

proc clear*(state: var TouchState) =
  ## Release contacts and queued samples after lost input synchronization.
  state.samples.setLen(0)
  for contact in state.pending.mitems:
    contact.active = false
    contact.id = -1
  state.commit()

proc apply*(state: var TouchState, kind, code: uint16, value: int32) =
  ## Accumulate evdev touch events until the next complete report.
  if not state.enabled:
    return
  if kind == 0 and code == 0:
    state.commit()
    return
  if kind == 3 and code == SlotCode and state.multitouch:
    let slot = int(value) - state.slotMinimum
    if slot notin 0 ..< state.pending.len:
      raise newException(IOError, "Touch event has an invalid slot")
    state.slot = slot
    return
  if state.pending.len == 0:
    return
  if kind == 1 and code == TouchCode and not state.multitouch:
    state.pending[0].active = value != 0
    state.pending[0].id = 0
  elif kind == 3:
    if state.multitouch:
      case code
      of TrackingCode:
        state.pending[state.slot].id = value
        state.pending[state.slot].active = value >= 0
      of PositionXCode: state.pending[state.slot].x = value
      of PositionYCode: state.pending[state.slot].y = value
      else: discard
    else:
      case code
      of 0: state.pending[0].x = value
      of 1: state.pending[0].y = value
      else: discard

proc touchPoint*(state: TouchState, contact: TouchContact, width, height,
    rotation: int): tuple[x, y: int] =
  ## Normalize and rotate one contact into logical screen coordinates.
  if state.maximumX <= state.minimumX or state.maximumY <= state.minimumY:
    raise newException(ValueError, "Touch coordinate range is invalid")
  let
    rawWidth = if rotation in [90, 270]: height else: width
    rawHeight = if rotation in [90, 270]: width else: height
    x = int((int64(clamp(contact.x, state.minimumX, state.maximumX)) - state.minimumX) *
      (rawWidth - 1) div (int64(state.maximumX) - state.minimumX))
    y = int((int64(clamp(contact.y, state.minimumY, state.maximumY)) - state.minimumY) *
      (rawHeight - 1) div (int64(state.maximumY) - state.minimumY))
  rotatedPoint(x, y, rawWidth, rawHeight, rotation)

proc targets*(width, height: int): array[9, tuple[x, y: int]] =
  ## Place touch targets at the corners, edge midpoints and center.
  let margin = max(24, min(width, height) div 16)
  for row in 0 .. 2:
    for column in 0 .. 2:
      result[row * 3 + column] = (margin + column * (width - 1 - margin * 2) div 2,
        margin + row * (height - 1 - margin * 2) div 2)

proc observe*(trace: var TouchTrace, state: TouchState, width, height, rotation: int) =
  ## Retain a bounded trail and mark targets reached by active contacts.
  let
    positions = targets(width, height)
    radius = max(20, min(width, height) div 24)
  let contacts = if state.samples.len > 0: state.samples else: state.contacts
  for contact in contacts:
    if contact.active:
      let
        point = state.touchPoint(contact, width, height, rotation)
        sample = TouchSample(id: int(contact.id), x: point.x, y: point.y)
      if trace.samples.len == 0 or trace.samples[^1] != sample:
        trace.samples.add sample
      for index, target in positions:
        if abs(point.x - target.x) <= radius and abs(point.y - target.y) <= radius:
          trace.tested[index] = true
  if trace.samples.len > MaximumTraceSamples:
    trace.samples = trace.samples[^MaximumTraceSamples .. ^1]
