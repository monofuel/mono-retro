import
  std/[algorithm, monotimes, os, parseopt, strutils, times],
  retro/[libretro, playerds, playerprofile]

const
  DefaultFrames = 600
  NanosecondsPerSecond = 1_000_000_000
  MillisecondsPerSecond = 1000
  Help = """Usage: benchmark_core --core:PATH --rom:PATH --save-dir:DIR [--load-state:PATH]
Options: --frames:N --warmup:N --ds-layout:combined|separate --earthbound-ds
         --option:KEY=VALUE --copy-video --copy-audio --pause-ms:N
Run uncapped without display, input or audio output. Core video/audio work remains
enabled; --copy-video additionally measures the frontend's normal video capture.
Use a disposable save directory: the session saves SRAM when it closes.
"""

proc main() =
  ## Measure the installed core without presentation, pacing or audio playback.
  var
    corePath, romPath, saveDirectory, statePath: string
    frames = DefaultFrames
    warmup, pauseMs: int
    earthboundDs, copyVideo, copyAudio: bool
    layout = NoDsLayout
    overrides: seq[CoreOption]
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
    of "warmup": warmup = parseInt(value)
    of "pause-ms": pauseMs = parseInt(value)
    of "ds-layout": layout = parseDsLayout(value)
    of "option":
      let separator = value.find('=')
      if separator < 1 or separator == value.high:
        raise newException(ValueError, "Expected --option:KEY=VALUE")
      overrides.add((value[0 ..< separator], value[separator + 1 .. ^1]))
    of "earthbound-ds": earthboundDs = true
    of "copy-video": copyVideo = true
    of "copy-audio": copyAudio = true
    else: raise newException(ValueError, "Unknown benchmark option: " & key)
  if corePath.len == 0 or romPath.len == 0 or saveDirectory.len == 0 or frames <= 0 or
      warmup < 0 or pauseMs < 0:
    raise newException(ValueError, Help)
  let
    dual = selectDualScreen(layout, earthboundDs)
    session = openCore(corePath, romPath, saveDirectory, options = dual.options & overrides,
      statePath = statePath, captureVideo = copyVideo, captureAudio = copyAudio)
  defer: session.close()
  echo "Core: ", session.info.libraryName, " ", session.info.libraryVersion
  echo "Target FPS: ", session.av.timing.fps
  var reported: seq[string]
  for key in ["melonds_jit_enable", "melonds_jit_block_size", "melonds_jit_fast_memory",
      "melonds_jit_branch_optimisations", "melonds_jit_literal_optimisations",
      "melonds_threaded_renderer", "melonds_render_mode"]:
    let value = session.coreOptionValue(key)
    echo "Option ", key, "=", (if value.len > 0: value else: "UNREGISTERED")
    reported.add(key)
  for option in overrides:
    if option.key notin reported:
      echo "Option ", option.key, "=", session.coreOptionValue(option.key)
      reported.add(option.key)
  for frame in 0 ..< warmup:
    session.step(benchmarkButtons(frame.uint64))
    if session.shutdown: raise newException(IOError, "Core requested shutdown")
  echo "PROFILE_READY pid=", getCurrentProcessId()
  stdout.flushFile()
  if pauseMs > 0: sleep(pauseMs)
  var frameTimes = newSeq[float64](frames)
  let started = getMonoTime()
  for frame in 0 ..< frames:
    let before = getMonoTime()
    session.step(benchmarkButtons((frame + warmup).uint64))
    if copyAudio: discard session.takeAudio()
    frameTimes[frame] = (getMonoTime() - before).inNanoseconds.float64 /
      NanosecondsPerSecond * MillisecondsPerSecond
    if session.shutdown: raise newException(IOError, "Core requested shutdown")
  let
    seconds = (getMonoTime() - started).inNanoseconds.float64 / NanosecondsPerSecond
    meanMs = formatFloat(seconds * MillisecondsPerSecond / frames.float64, ffDecimal, 3)
    fps = formatFloat(frames.float64 / seconds, ffDecimal, 2)
    speed = formatFloat(frames.float64 / seconds / session.av.timing.fps * 100, ffDecimal, 2)
  frameTimes.sort()
  echo "Measured frames: ", frames, "; warmup: ", warmup
  echo "Frames: ", session.frames, "; video: ", session.videoFrames,
    "; audio frames: ", session.audioFrames, "; copy video: ", copyVideo,
    "; copy audio: ", copyAudio
  echo "Mean ms/frame: ", meanMs, "; uncapped fps: ", fps, "; speed percent: ", speed
  echo "Frame ms: min=", frameTimes[0], "; p50=", frameTimes[(frames - 1) div 2],
    "; p95=", frameTimes[(frames - 1) * 95 div 100], "; max=", frameTimes[^1]

main()
