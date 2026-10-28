import
  std/math

type
  FrameClock* = object
    period*, deadline*: int64

proc newFrameClock*(fps: float, now: int64): FrameClock =
  ## Use the core's nominal rate instead of assuming sixty frames per second.
  if fps.classify in {fcNan, fcInf, fcNegInf} or fps <= 0 or fps > 1000:
    raise newException(ValueError, "Invalid core frame rate")
  FrameClock(period: int64(1_000_000_000.0 / fps), deadline: now)

proc reset*(clock: var FrameClock, now: int64) =
  ## Resume at the current time without accumulating paused frames.
  clock.deadline = now

proc advance*(clock: var FrameClock, now: int64) =
  ## Preserve steady deadlines and avoid burst catch-up after a slow frame.
  clock.deadline += clock.period
  if clock.deadline < now: clock.deadline = now
