import
  std/[monotimes, os, parseopt, strutils, times],
  retro/[libretro, playerds]

const
  DefaultFrames = 600
  NanosecondsPerSecond = 1_000_000_000
  MillisecondsPerSecond = 1000
  Help = """Usage: benchmark_core --core:PATH --rom:PATH --save-dir:DIR [--load-state:PATH]
Options: --frames:N --earthbound-ds --copy-video
Run uncapped without display, input or audio output. Core video/audio work remains
enabled; --copy-video additionally measures the frontend's normal video capture.
Use a disposable save directory: the session saves SRAM when it closes.
"""

proc main() =
  ## Measure the installed core without presentation, pacing or audio playback.
  var
    corePath, romPath, saveDirectory, statePath: string
    frames = DefaultFrames
    earthboundDs, copyVideo: bool
    parser = initOptParser(commandLineParams())
  for kind, key, value in parser.getopt():
    if kind != cmdLongOption: raise newException(ValueError, Help)
    case key
    of "help": stdout.write(Help); return
    of "core": corePath = value
    of "rom": romPath = value
    of "save-dir": saveDirectory = value
    of "load-state": statePath = value
    of "frames": frames = parseInt(value)
    of "earthbound-ds": earthboundDs = true
    of "copy-video": copyVideo = true
    else: raise newException(ValueError, "Unknown benchmark option: " & key)
  if corePath.len == 0 or romPath.len == 0 or saveDirectory.len == 0 or frames <= 0:
    raise newException(ValueError, Help)
  let
    dual = selectDualScreen(NoDsLayout, earthboundDs)
    session = openCore(corePath, romPath, saveDirectory, options = dual.options,
      statePath = statePath, captureVideo = copyVideo)
  defer: session.close()
  let started = getMonoTime()
  for frame in 0 ..< frames:
    session.step(0)
    if session.shutdown: raise newException(IOError, "Core requested shutdown")
  let
    seconds = (getMonoTime() - started).inNanoseconds.float64 / NanosecondsPerSecond
    meanMs = formatFloat(seconds * MillisecondsPerSecond / frames.float64, ffDecimal, 3)
    fps = formatFloat(frames.float64 / seconds, ffDecimal, 2)
  echo "Core: ", session.info.libraryName, " ", session.info.libraryVersion
  echo "Frames: ", session.frames, "; video: ", session.videoFrames,
    "; audio frames: ", session.audioFrames, "; copy video: ", copyVideo
  echo "Mean ms/frame: ", meanMs, "; uncapped fps: ", fps

main()
