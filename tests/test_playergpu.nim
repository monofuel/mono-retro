import
  std/unittest,
  retro/playergpu

suite "GPU player presentation":
  test "automatic GPU use requires the proven native capabilities":
    check useGpuVideo(AutoVideo, "drm", 2, 0, true)
    check not useGpuVideo(AutoVideo, "drm", 2, 0, false)
    check not useGpuVideo(AutoVideo, "x11", 2, 0, true)
    check not useGpuVideo(AutoVideo, "fbdev", 1, 90, true)
    check not useGpuVideo(CpuVideo, "drm", 2, 0, true)
    check useGpuVideo(GpuVideo, "drm", 2, 0, false)
    expect ValueError: discard useGpuVideo(GpuVideo, "x11", 2, 0, true)
    expect ValueError: discard useGpuVideo(GpuVideo, "drm", 2, 90, true)
  test "DS and companion panels stay in one combined source":
    check playerCrops(256, 384, 256, 192, 1, true) ==
      [(0, 0, 256, 192), (0, 192, 256, 192)]
    check playerCrops(256, 448, 256, 224, 1, true) ==
      [(0, 0, 256, 224), (0, 224, 256, 224)]
    expect ValueError: discard playerCrops(256, 448, 256, 192, 1, true)
  test "single-screen games swap the crop and retain a black inactive panel":
    check playerCrops(240, 160, 0, 0, 0, false) ==
      [(0, 0, 240, 160), (0, 0, 0, 0)]
    check playerCrops(240, 160, 0, 0, 1, false) ==
      [(0, 0, 0, 0), (0, 0, 240, 160)]
    expect ValueError: discard playerCrops(240, 160, 0, 0, 2, false)
  test "video overrides reject mistakes":
    check parseVideoMode("auto") == AutoVideo
    check parseVideoMode("cpu") == CpuVideo
    check parseVideoMode("gpu") == GpuVideo
    expect ValueError: discard parseVideoMode("gup")
