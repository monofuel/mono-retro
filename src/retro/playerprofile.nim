when defined(playerTimings):
  import
    std/[monotimes, strutils]

type
  PlayerStage* = enum
    CoreWork, VideoCopy, AudioCapture, AudioOutput, ScreenSplit, Scaling,
    Presentation, Events, Waiting, Saving

when defined(playerTimings):
  const NanosecondsPerMillisecond = 1_000_000
  var stageTicks: array[PlayerStage, int64]

template measured*(stage: PlayerStage, body: untyped) =
  ## Collect stage time only in builds explicitly enabling playerTimings.
  when defined(playerTimings):
    let started {.gensym.} = getMonoTime().ticks
    body
    stageTicks[stage] += getMonoTime().ticks - started
  else:
    body

proc resetTimings*() =
  ## Exclude initialization callbacks from the measured frame loop.
  when defined(playerTimings):
    stageTicks = default(array[PlayerStage, int64])

proc printTimings*(frames: uint64) =
  ## Report exclusive average stage costs; core calls include capture callbacks.
  when defined(playerTimings):
    if frames == 0: return
    for stage in PlayerStage:
      let
        ticks = if stage == CoreWork:
            stageTicks[stage] - stageTicks[VideoCopy] - stageTicks[AudioCapture]
          else: stageTicks[stage]
        milliseconds = ticks.float64 / frames.float64 / NanosecondsPerMillisecond
        value = formatFloat(milliseconds, ffDecimal, 3)
      echo "Timing ", stage, " ms/frame=", value
