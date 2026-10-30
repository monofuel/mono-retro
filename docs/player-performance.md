# mono-retro-player performance roadmap

The target is a frontend that preserves native game pixels, does little CPU
pixel processing, presents without tearing, and keeps audio delivery stable.
Start with the cheapest possible data flow and measure backward from it.
This is a working roadmap, not a commitment to implement every candidate.

## Current state

Already implemented in the player or the Windy handheld fork:

- Shipped compiler settings by default, with checked developer/debug builds.
- A dedicated core worker, one frame in flight, recycled image storage and
  serialized save/state operations. The main thread owns input, Slappy and display.
- ARM64 SIMD conversion for ordinary libretro XRGB8888 frames.
- Integer scaling that clears borders rather than clearing the image interior
  before overwriting it. Native dual-screen output retains unchanged panels.
- Bounded frame-clock catch-up and audio underrun/overrun counters.
- Windy DRM double buffering and vblank page flips. Tearing was manually resolved
  on the DS Plus; this does not establish full-speed emulation or clean audio.
- Optional opaque XBGR negotiation and direct row capture, described below.
- Paired Panfrost presentation on the source-kernel DS Plus: one native texture,
  GPU integer scaling, paired atomic updates and retained unchanged scanout.

The core worker overlaps emulation with presentation, but the main thread still
requests the next step and queues completed PCM. Display waits can therefore
still affect scheduling. Capture still uses Pixie images. The CPU path splits,
scales and uploads full panels; the GPU path consumes the native combined image.
Standard XRGB conversion remains on the worker; private XBGR avoids it.

Decompbound is mildly crunchy around inventory/menu work. melonDS DS is much
crunchier and needs its own profile. A separate agent owns Decompbound internals;
this roadmap concentrates on the shared frontend and display stack.

## Reference measurements

These DS Plus measurements use the same imported EarthBound state and copied
saves, before core-side XBGR integration. They are workload-specific baselines,
not whole-game results or promises about newer core builds. The core-and-capture
runs have no display or audio output.

| Workload | Mean frame time | Peak | Frames above 16.67 ms |
| --- | ---: | ---: | ---: |
| Goods inventory, DS companion/output enabled | 17.13 ms | 18.57 ms | 40 / 60 |
| Same inventory inputs, companion/output disabled | 15.89 ms | 17.18 ms | 1 / 60 |

The difference includes companion work, frame packing and the larger captured
image; it does not identify one internal hotspot. At 60 FPS the budget is
16.67 ms, so the first case already misses its deadline without presentation.
Use each core's reported rate rather than assuming every core runs at 60 Hz.

A separate moving full-player test spent roughly 3–4 ms per frame on CPU panel
splitting/comparison, scaling and presentation. That work overlaps the core and
must not simply be added to the headless figures. Standing still hides much of
this cost because unchanged panels skip redraws.

## 1. Keep pixels in their original useful format

The current ordinary software path is:

```text
core's internal RGBA -> libretro XRGB8888 -> player/Pixie RGBA
                    -> CPU split/scale -> display buffers
```

The DS Plus display controller accepts both XRGB8888 and Pixie-compatible
XBGR/ABGR layouts. Pixie is not incompatible with the display; insisting on a
Pixie Image after every libretro callback causes the conversion back to RGBA.

### Opaque XBGR: frontend implemented, device integration confirmed

The [private extension](libretro-extensions.md) lets a cooperating core keep its
opaque Pixie bytes unchanged. The host copies rows rather than swapping channels.
Its contract and C constants live in
[`include/mono_retro_libretro.h`](../include/mono_retro_libretro.h).

- Private environment command `0x24D52`, pointer to uint32 FourCC `0x34324258`.
- Accepted pixels are little-endian bytes **R, G, B, 255**. The opaque filler
  requirement is deliberate; the frontend performs no alpha normalization.
- Rejection leaves the active format unchanged. The core then requests standard
  XRGB8888 and retains its existing packing path for other/older frontends.
- Dual-screen composition may still copy top/bottom rows into a combined buffer.
  Eliminating channel conversions is separate from eliminating copies.

Monofuel confirms the Decompbound implementation is merged to master and tested
on the RG DS Plus. The frontend also has desktop/ARM64-QEMU coverage, including
colour identity and fallback to an older host. Preserve these checks as the
presentation path changes.

For ordinary cores such as melonDS DS, the future presentation path should
consume native XRGB directly too. Carry width, height, byte pitch, pixel format
and buffer ownership explicitly instead of requiring every frame to become a
Pixie Image. Pixie remains useful for the launcher and UI.

## 2. Prove the cheapest presentation path

Investigate the DS Plus first. Preserve X11 and the RG SP's working fbdev path.
A DRM device and advertised formats do not establish GPU acceleration or scaler
capabilities. Identify the actual render driver and test the required operations.

### Candidate A: display-controller cropping/scaling

The leanest path may not require a GPU draw at all:

```text
native-size buffer -> KMS plane crop/scale -> panel scanout
```

Questions for a focused capability probe:

- Can both active primary planes scale the required source rectangles to the
  integer-sized destination, with centered black borders?
- Can each output select its half of one combined image, or are separate buffers
  required? Can their framebuffers reference the same allocation?
- Does scaling preserve exact nearest-neighbour pixels? Use checkerboards and
  output capture where available, otherwise manual inspection. Reading the native
  source buffer does not verify the display controller's scaling result.
- Which source sizes, formats, pitches, modifiers and scaling ratios work?
- Can both outputs update without serializing into two refresh waits?

A native-size copy into a controller-owned buffer can still be a large win if it
removes CPU scaling and full-screen copies. Shared RAM alone does not make an
arbitrary core pointer a valid scanout allocation. A shared buffer must remain
owned until every output using it has completed its flip.

### Candidate B: GPU texture presentation

If plane scaling cannot meet the requirements, investigate a small GBM/EGL
presentation path through Windy:

```text
native-size frame -> one texture upload -> crop/scale quads for both screens
                  -> GPU-rendered scanout buffers -> synchronized KMS flips
```

- Verify the Mesa/vendor driver, render node, EGL/GBM support and compatible
  OpenGL ES/OpenGL context before choosing a rendering implementation.
- Upload the combined native image once; both outputs sample their own region.
- Let texture formats or the shader handle channel interpretation. Keep CPU
  channel swaps and screen-sized Pixie canvases out of this path.
- Preserve nearest-neighbour integer scaling, borders, cropping and screen order.
- Measure texture upload, GPU work, presentation submission and buffer waits
  separately. A fast asynchronous submission is not the complete frame cost.

Windy should own generic native contexts, display buffers and presentation.
mono-retro-player owns libretro transport, layout and application scheduling.
Keep Paddy input and Slappy audio, and keep game/device-specific policy in the app.
Use the existing Nim/library stack for generic backend work.
Choose one proven path before building a broad rendering abstraction.

### Selected experiment: GPU rendering with paired atomic presentation

Read-only inspection of the running source kernel identifies rockchip-drm on
card0 and Panfrost on card1/renderD128. The upstream VOP2 scaler selects
bicubic/bilinear enlargement; our kernel patches do not change its filtering.
The first experiment therefore uses GPU nearest-neighbour rendering, preserving
the desired crisp pixels without kernel changes.

Windy's isolated `monofuel/drm-gpu-proof` branch contains a standalone diagnostic,
documented in its `docs/drm-gpu-proof.md`. It uploads one combined XRGB/XBGR source
texture, renders both panels into one linear 1024×1536 GBM allocation, and uses
two 1:1 primary-plane crops. Both plane framebuffer changes are submitted in one
atomic transaction. Buffer retirement waits for both CRTC completion events;
there is at most one pending pair. This coordinates the same frame on both
outputs without claiming physically phase-locked panel refresh.

The test compares every GPU-rendered pixel against the integer-scaled synthetic
pattern before scanout. It measures CPU time, upload/render/finish/submission,
waits and per-output completion skew. `glFinish` is intentionally conservative;
explicit fencing/overlap and player integration follow measured success. The
standalone proof keeps player behavior unchanged. Its reusable integration is
described below; X11 and fbdev retain their existing paths.

Device requirements are Mesa's Panfrost driver, EGL, GBM and GLES, with X11,
Wayland and runtime LLVM disabled. Gentoo's Panfrost shader compiler still has
build-time LLVM/Clang/libclc dependencies. Heavy portable builds should use the
MLE Gentoo builder. The DS Plus has its portable client and matching distcc
target configured; local source generators/linkers still need their own RAM.

The standalone hardware proof passes with Mesa 26.1.8's Mali-G52 Panfrost driver.
All pixels/borders match exactly in both layouts and both formats. One shared
framebuffer passes atomic testing and paired flips, with both completion events
before retirement. Eight-second synthetic runs stay near 60 FPS: main-thread
CPU time falls from about 7.60 ms/frame to 1.94 ms for DS-sized XBGR and 2.12 ms
for EarthBound-sized XBGR. XRGB scanout works too. Completion timestamps remain
about 6.1 ms apart, so this does not establish physical panel phase lock.

EGL configuration must explicitly exclude depth, stencil and MSAA: an initial
16× multisampled configuration took about 78 ms waiting for the GPU. The final
configuration brings render/swap/finish to about 5 ms. Details and comparison
limits are in Windy's proof guide on `monofuel/drm-gpu-proof`.

These synthetic results alone do not establish an emulator speedup.
Monofuel confirms both synthetic layouts look correct: upright and crisp, correct
screen order, smooth markers, even borders and no visible moving tears. The
launcher is restored; the proof uses no audio.

### Player integration

Windy's `monofuel/drm-gpu-player` branch exposes `windy/drmpixels`: two idle
native windows, one Pixie image and two source crops. Its guide is
`docs/drm-pixel-pairs.md`. GPU resources close before the windows; libraries load
lazily, so CPU-only users need no Mesa. Device policy remains in this app.

The player defaults to GPU presentation for two unrotated DRM outputs with a
Panfrost render driver. `--video:cpu` retains the existing path; `--video:gpu`
requires GPU presentation and reports failures. Single-screen games/L2 use a
black inactive crop. Before recycling storage, the worker optionally compares
the new image with its predecessor. Identical video therefore needs no extra
copy, upload or display wait.

A matched muted EarthBound DS walking test runs360frames in about6s on both
paths. Frontend-thread CPU is roughly3.9→1.5ms/frame and total process CPU
14.0→11.0ms/frame: about62% and22% lower. GPU stage wall time includes vblank
waits and is not CPU work. Process timing explicitly counts every worker rather
than using Linux's thread-only Nim `cpuTime`. These are scene-specific results.

Muted melonDS DS boot tests also pass. GPU readback covers source crops, odd
borders, resizing, clipping, black outputs and swaps. X11/GLX, wheel handling,
core/worker tests and RG SP compilation retain coverage. Audible playback and
manual gameplay acceptance remain separate. Preserving raw XRGB through capture,
instead of first normalizing it to Pixie RGBA, remains a future transport change.

## 3. Make stalls measurable and scheduling explicit

Add low-overhead per-frame diagnostics, with graphs or a bounded trace when
useful. Average FPS alone hides the hitches that coincide with audio crackles.

Capture core/callback time, panel work, upload time, flip/fence waits, input/event
work, autosave and frame age. Report peaks/percentiles and missed deadlines.
Correlate those with audio queue depth and underrun/overrun timestamps. Check
allocation pressure, per-thread CPU use, frequency and temperature before
attributing a spike to GC, throttling or a particular library.

The current audio queue primes at 30 ms and caps queued PCM at 100 ms, excluding
OpenAL/OS/device buffering. More buffering may absorb brief jitter but adds
latency and cannot fix sustained insufficient emulation throughput.

Investigate whether presentation waits should be decoupled further from core
scheduling and audio feeding. Keep ownership explicit, queues bounded and pause,
state-import and shutdown behavior deterministic. A display may retain its last
frame or replace an obsolete pending presentation without skipping emulated
frames/audio. Avoid growing a backlog that makes controls feel sluggish.

Measure clock drift separately from slow frames before selecting audio-driven
pacing or adaptive resampling. Both are candidates, not implemented policy.

## 4. Remove further copies only when justified

After native-format presentation works, count the remaining copies and bytes:

- Core-side assembly of two images into the combined libretro frame.
- Capture of the core's borrowed callback buffer into frontend-owned storage.
- Texture upload or copy into native scanout storage.

Libretro's existing `GET_CURRENT_SOFTWARE_FRAMEBUFFER` interface can let a core
render into frontend-provided memory. It is not implemented by the player yet;
the private XBGR extension only negotiates a format. A later experiment could
use suitable CPU-writable GPU/display allocations, provided the core cooperates.

Validate pitch, alignment, cache visibility, fences, callback lifetimes and
reuse after both displays finish. Preserve duplicate-frame semantics. Two or
three buffers may be appropriate, but extra buffers must earn their latency
and memory cost. GPU/display mappings can be slower for CPU rendering than
ordinary RAM plus an upload; compare both rather than assuming zero-copy wins.
Consider asynchronous uploads only if upload time is material.

## 5. Profile melonDS separately; hardware-rendered cores are another layer

Compare core-only time with full-player time for a reproducible Lost in Blue
workload. Verify runtime JIT and renderer choices: the ARM core build enables
JIT/threaded-renderer support, but that alone does not prove the effective runtime
settings. Do not transfer Decompbound's measured bottleneck to melonDS.

The current melonDS build is software-rendering, with OpenGL disabled, and the
player does not implement libretro hardware-rendering context negotiation.
A GPU-powered frontend only accelerates presentation. Letting an emulator render
through the GPU requires a separate `SET_HW_RENDER`/context/framebuffer lifecycle
implementation and a compatible core build. Revisit this after the native GPU
presentation/context path is understood.

Decompbound CPU/PPU/APU and companion profiling belongs with its core agent.
GPU presentation cannot guarantee full speed when core execution alone exceeds
the frame budget.

## Delivery order and acceptance

1. Confirm XBGR integration and retain reproducible before/after workloads.
2. Inspect DS Plus plane/GPU capabilities, then prove the selected path with a
   standalone native-format pattern/animation test, independent of an emulator.
3. Integrate native-format frame transport and presentation; measure before/after
   CPU cost, waits, frame pacing, audio starvation and input responsiveness.
4. Use the measurements to prioritize scheduling/audio work and further copies.
5. Profile melonDS options/internal costs and assess hardware-rendered cores.

Keep short device reproductions within ten seconds; crunchy audio is immediate.
Use a wall-clock bound as well as a frame limit when a core may run slowly.
Use copied saves and read-only source states, including moving and menu-heavy
cases. Record actual selected formats/backends and compiler settings. Synthetic
patterns must test colours, opaque bytes, integer pixels, borders, both outputs,
duplicates and cleanup. Preserve desktop resize/focus/touch/state-import behavior.
Benchmark shutdown and compare live/retained buffers carefully when changing
presentation ownership. Do not interrupt an active game to run a display probe.

The [player README](../README-player.md#performance-diagnostics) contains existing
benchmark commands and regression checks. Keep game data, captures and compiled
artifacts out of source commits.
