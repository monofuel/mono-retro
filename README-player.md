# mono-retro-player

A libretro player using Nim, Windy, Pixie, Paddy and Slappy. Targets include
Mother 3 with mGBA on X11, decompbound on both handhelds and melonDS DS on X11
and the RG DS Plus. The player
can run independently or as a child of the launcher. Existing core-defined states
can be imported; state creation and ROM browsing are future work.

## Build and run

Follow the [Nimby workspace setup](README.md#build), then build with
`make player-desktop`. The project's `nimby.lock` pins all Nim dependencies,
including the Windy GPU and Paddy controller-discovery forks. Native Linux
dependencies are libudev, libevdev, libX11, libXcursor, OpenGL/GLX, OpenAL Soft and OpenSSL,
plus a C compiler for the ABI bridge.

For library development in a separate Windy worktree, set
`MONO_RETRO_WINDY=/path/to/windy-checkout`. This overrides the locked Windy
checkout for builds and checks. During development of X11 GPU presentation, use
`MONO_RETRO_WINDY=../windy-gpu-player` in the shared local workspace; its ordinary
`../windy` checkout is on an older, independent branch. Clean workspaces use the
revision pinned by this project's lock file.

On NixOS, the scoped development shell supplies native build/runtime libraries:

```sh
nix-shell shell-player.nix
make player-desktop
build/mono-retro-player --help
```

Select the core, uncompressed ROM and save directory explicitly:

```sh
build/mono-retro-player \
  --core:build/cores/mgba_libretro.so \
  --rom:'build/player-test/Mother 3 (English v1.3).gba' \
  --save-dir:build/player-test/saves
```

This command needs an X11 display, including XWayland on a Wayland desktop.
The local working ROM and core under `build/` are ignored by Git. The player
does not download cores or ROMs, extract archives, or search the game collection.

For the first test, the core came from `nixpkgs#libretro.mgba`, version
`0-unstable-2026-04-03`, built from
[libretro/mgba commit 6dce57eef127dc4cc292644f38196e0e7c58590c](https://github.com/libretro/mgba/tree/6dce57eef127dc4cc292644f38196e0e7c58590c).
`nix build --out-link build/cores/mgba-package nixpkgs#libretro.mgba` obtains it
and keeps its runtime dependencies reachable by Nix's garbage collector. The
library is at `lib/retroarch/cores/mgba_libretro.so` inside that package.
Copy it into `build/cores/` if using the command above. A normal system
package providing the mGBA libretro core also works. These are external runtime
artifacts, not Nim dependencies; no SDL frontend is used.

## Import an existing state

Add `--load-state:/absolute/path/to/state` to the normal player command, or
drop a state file onto any running desktop player window. The frontend passes
the bytes to the core's `retro_unserialize`; formats and compatibility belong
to the core. Decompbound accepts its raw DBST v1/v2 `.state` files and F12 PNG
screenstates containing `ebSt`. Other cores require their own state formats.

Startup imports run after disk SRAM loading. Invalid/missing state files or
unsupported cores fail startup before save persistence is enabled. A successful
drop clears queued audio and input, restarts frame pacing, and focuses that
window. Rejected drops report a reason in the terminal while the app stays
open; decompbound validates before changing its live state.

State import can restore battery SRAM, which normal autosave/exit persists in
the selected `--save-dir`. Use a separate test-save directory. Source state
files are never rewritten. Native DRM has no desktop file-drop events; use
`--load-state` on handhelds. Cores without state support still run normally.

## Screenstates and recorded sessions

**F12** (or a controller Share button exposed by Paddy as `GamepadMisc0`) captures
a resumable PNG. The image contains the complete core frame, including both screens
in DS layouts, without the achievement overlay or window scaling. Drop the PNG onto
either desktop window, or pass it with `--load-state`, to resume. Decompbound captures
use its existing `ebSt` format; other cores use a frontend `mrSt` envelope that checks
the ROM and core build before importing the opaque core state.

Normal play records inputs automatically from an initial checkpoint. Every five
seconds of active play, a plain screenshot records its segment and replay-frame
position in a sidecar. These periodic PNGs are not self-contained screenstates.
F12 and orderly exit capture full screenstates. A successful state import starts a
new recording segment. Recording includes every emulated frame during fast-forward,
not just frames presented on screen, and includes pointer input.

Sessions live under `SAVE_DIR/captures/`; the player prints the full session path.
F12/controller Share and orderly-exit screenstates also appear in
`~/Pictures/Screenshots/`, matching the standalone Decompbound player. These are
byte-identical copies with the embedded state intact; session originals and
replay sidecars stay together. Existing files are preserved by adding a numeric
suffix on a name collision. Five-second plain screenshots remain session-only.
Use `--capture-dir:DIR` to choose another location or `--captures:off` to disable
capture and recording for benchmarks; `--capture-dir` changes the session root,
while screenstates still appear in the Pictures folder. PNG compression and disk writes run on a
separate writer thread; the core's state is copied between frames on its owner thread.
Exit waits for queued writes to finish. Cores without state export retain plain
image captures, but cannot produce screenstates or replay recordings.

Replay a segment with `--replay:/path/to/segment_0001.json`, the same `--core` and
`--rom`, and the same core-option flags such as `--earthbound-ds`. Replay stops at
the recorded end, uses recorded inputs, and disables achievements. Use a separate
`--save-dir` when replaying because restored state can replace battery saves.
Recordings require the original ROM and exact core binary and are not portable
across core builds. Keep captures, checkpoints and recordings private and out of Git.
To reconstruct a periodic screenshot, use its sidecar's `replay` filename with
`--replay` and its `frames` count with `--frames:N`; the exit screenstate saves that
moment. The manifest and log are flushed before the screenshot is written, so a
capture can be replayed while its original session remains open.

## Controls

| Input | GBA action |
|---|---|
| Arrow keys | D-pad |
| X / Z | A / B |
| A / S | L / R |
| Enter / Backspace | Start / Select |
| Escape | Save and exit |
| F1 / controller Menu or Home | Pause menu: save/load states, achievements and exit |
| F12 / controller Share | Capture a resumable screenstate |
| Hold controller R2 / Tab | Fast-forward up to 4×; release for normal speed |

The pause menu and achievement browser consume Escape/B to return. See
[RetroAchievements setup](docs/retroachievements.md) for the login helper and
Casual-mode support in Decompbound.

The first connected Paddy controller (lowest device ID) maps physical RetroPad
positions: east is A, south is B, north is X and west is Y; shoulders are L/R.
The left stick also supplies eight-way D-pad input past half travel on either
axis. Digital D-pad input takes precedence on the same axis. The right stick
does not move the D-pad. Keyboard and controller buttons
combine. Unplugging the controller removes its held buttons. Device-specific
mapping remains an application concern.

R2 is reserved by the player for fast-forward instead of reaching the core.
Fast-forward runs every emulated frame and presents every fourth frame, keeping
vsync enabled. Actual speed depends on the core and hardware. Audio is muted
while held and reprimes at normal speed on release. Focus loss and the paused
achievement browser stop fast-forward. Page Down still supplies the core's R2.

Desktop emulation pauses while the window is unfocused or minimized. On resume the
clock starts from the current time. Frames follow the core's reported rate
(mGBA reports about 59.73 Hz), recovering up to two frames of timing debt before
resetting after a longer stall. One dedicated thread owns the software core and
its callbacks, including initialization, saves and state imports. It computes at
most one frame ahead while the main thread handles input, audio and presentation.
Frame buffers transfer ownership between threads; duplicate video callbacks retain
the displayed image. This overlap avoids adding display work to the emulation
thread's frame budget. The software capture path
copies pitch-aware RGB565, XRGB8888 or 0RGB1555 frames, repeats duplicate frames,
and scales by the largest whole-number factor that fits (1×, 2×, 3×, …), centered
inside black borders. Pixels stay square; the core's display-aspect hint does not
stretch the image. The window starts at the core's native base resolution (for
example, 240×160 for GBA). Below native size, the image remains at 1× and is
center-cropped. Hardware rendering requests are unsupported.

On X11, `--video:auto` (the default) uploads native-size images into persistent
OpenGL textures. The GPU scales and crops them with nearest filtering, and GLX
swaps double buffers with vsync enabled. This replaces unsynchronized CPU
`XPutImage` uploads. Both windows draw before swapping; resizing redraws even
when the core repeats its previous frame. No additional channel conversion is
introduced. This accelerates presentation of software cores, not core rendering.
`--vsync:off` is available for diagnostics and isolated Xvfb tests; it permits
tearing. Startup reports the selected path and fails if requested GLX swap
control is unavailable. Physical tear-free behavior still needs manual checking.

On the source-kernel DS Plus, `--video:auto` uses Panfrost for two
unrotated DRM outputs. One native-size texture feeds both screens, with GPU
nearest-neighbour integer scaling, black borders and one paired atomic commit.
Old storage is retained until both controllers complete. Single-screen games
keep the other output black and L2 swaps them. Duplicate callbacks and identical
fresh frames retain scanout without another upload. fbdev and stock-kernel
CPU playback keep their existing paths.

`--video:cpu` selects the existing path for comparison/recovery; `--video:gpu`
requires X11 GPU windows or the paired DRM path. Selection is at startup. GPU initialization errors are
reported rather than silently switching renderers. DRM GPU playback requires Mesa's
hardware driver, libgbm, libEGL and libGLESv2, loaded only when requested. It needs
no X11/Wayland server. Frames still use Pixie capture: standard libretro XRGB is
converted on the worker, while the private XBGR path avoids that conversion.

CPU DRM playback requests synchronized presentation from Windy.
Each screen uses two buffers and switches at vblank, avoiding writes
into the currently visible buffer. Uploads wait for the previous switch before
reusing its storage; the frame clock still sets the emulation rate. This requires
the fork's DRM page-flip support. CPU X11 and fbdev use unsynchronized uploads.

`--frames:N` exits after N emulated frames for bounded tests. Window close,
SIGINT and SIGTERM also save and exit.

## EarthBound DS companion

The optional `--earthbound-viewport:WIDTHxHEIGHT` selects the game panel size
(width 256–1024, height 224–1024; default 256x224). The Party panel remains
256x224. Desktop windows start at 2x, or use `--earthbound-scale:N` to start
the Game window at an exact integer scale; `auto` uses the largest integer that
fits on resize. Party scales independently. A forced scale works with X11 GPU
or CPU video and rejects a window too small to display it. Native forced-scale
experiments still use CPU video. Both options require
`--earthbound-ds`.

With decompbound's dual-screen core, add `--earthbound-ds` to the normal player
command. This preset enables `decompbound_dual_screen=enabled` and requires a
256×448 software frame by default: two stacked 256×224 panels. With a custom
`W×H` viewport, the frame is `W×(H+224)`, with the 256×224 Party crop centered
below the game and black padding on its sides. The core must support the
viewport options for non-default sizes. The preset cannot be combined with
`--ds-layout`, which retains its melonDS-specific options and geometry.

On X11, the default **Game** and **Party** windows start at 512×448 (2×) and
resize independently. Custom game dimensions change only the Game window's
initial size. Expanded terrain remains experimental; see
decompbound's `docs/expanded-viewport.md` for its scene coverage and test commands.
For the existing handheld mode, use the ordinary `player-rg-ds-plus` build with
`--earthbound-ds` and the device profile matching the installed kernel. The
profile selects the two physical outputs. At default dimensions, both panels
use integer scaling and centering: 768×672 (3×) on 1024×768 displays. EarthBound DS
targets 2× and above; original DS-size 1× layouts are outside its MVP.

The core draws party HP/PP and browsable inventory. Tap/click a card or use
**L2** / **Page Up** for the previous character and **Page Down** for the next.
Touch can select any card; controller R2 instead fast-forwards. L2 reaches the
core instead of swapping physical displays. Gameplay
controls keep working; item use and battle commands remain in the game menus.
Only lower-panel touches inside the scaled image reach the companion. The
existing first-contact touch policy, focus pause, audio, SRAM persistence and
either-window exit behavior apply.

Use a separate `--save-dir` for testing. On 2026-10-31, the RG DS Plus
Decompbound test wrappers were updated to 336x256 with player `eb6e273` and
core `82e1285`, retaining automatic GPU/integer scaling and the existing Jeff
startup state. Silent loader/core checks passed; physical-screen acceptance
and sustained performance remain manual checks. Decompbound's
`docs/earthbound-ds.md` documents its build/run targets and physical checks.

## Lost in Blue with melonDS DS on X11

From this repository, choose a mode when launching:

```sh
nix-shell shell-player.nix --run 'make play-lost-in-blue DS_LAYOUT=combined'
nix-shell shell-player.nix --run 'make play-lost-in-blue DS_LAYOUT=separate'
```

Combined mode starts one 256×384 window with the DS top screen above its touch
screen. Separate mode starts independently resizable Top and Touch windows at
256×192 each. Both retain integer scaling and black borders. Left-click/drag on
the lower screen supplies touch input; clicks on the top screen or borders do
not. Keyboard controls work in either focused game window; W/Q add DS X/Y to
the existing controls. Closing either window or Escape saves and exits. Playback
pauses when neither game window is focused and drawable.

Setup makes real copies of the retained cartridge ROM and **original `.sav`**
from `~/Documents/Arcade/cartridge-dumps/DS/Lost in Blue/` into ignored
`build/player-test/melonds-lost-in-blue/`. The copied save is renamed to
`saves/LOST_IN_BLUE_ASKEA4_00.srm`. Subsequent launches keep test progress;
they do not reseed that save. The helper rejects linked working files, and the
ROM and save originals remain outside the writable emulator directories.
Both layouts share the working save; exit one before launching the other.
`LOST_IN_BLUE_SOURCE` overrides the source directory for another local copy.

The tested core is Nixpkgs `libretro.melondsds` 1.2.0, upstream commit
[`33c4826`](https://github.com/JesseTG/melonds-ds/tree/33c48260402865ef77667487528efd5ca7ce1233),
licensed GPLv3. Its dependencies remain reachable through
`build/cores/melondsds-package`; the library is
`lib/retroarch/cores/melondsds_libretro.so` within that package. The tested
library SHA-256 is `f4d45240257317e12f9dd3b11fead78f58b643d9607053c431047580089a46a1`.
ROMs, saves and core binaries are not tracked in Git.

The generic player also accepts `--ds-layout:combined|separate`. This opt-in
preset selects software rendering, native top/bottom order with no gap, one fixed
core layout and pointer input. Software rendering is the pinned core's default;
software-only builds do not expose a renderer-choice option. It requires
256×384 video. Both layouts work on
X11; native DRM requires separate layout and exactly two outputs. Core option
overrides use the existing legacy libretro options API; unsupported requested
options fail explicitly. Our Windy fork includes the X11 event-predicate ABI fix
needed to route focus and mouse input independently between the two windows.

The tested cartridge boots with the core's built-in FreeBIOS and firmware.
The core's touch cursor is hidden. Set the compile-time `ShowDsTouchCursor`
constant in `src/retro/playerds.nim` to `true` to show it for diagnostics.
Audio output uses Slappy as usual. Microphone input is disabled for this MVP;
Lost in Blue interactions requiring blowing remain unavailable. Switching
layouts during play is deferred.

## Handhelds

`make player-rg-sp` builds `build/mono-retro-player-rg-sp` with the fbdev backend
for the RG SP's vendor kernel. It uses the same ARM64 cross-link directory as
the DS Plus, without libdrm. Runtime libraries must match the target's CPU and
Gentoo ABI; install OpenAL with ALSA enabled for the RG SP's Cortex-A53.
The RG SP uses `/dev/fb0` and the existing app-owned controller mapping, with
the named `mono_retro_test` ALSA PCM. It has one screen, so L2 stays a core input.
Hold Select+Start for two seconds to save and return to the launcher.

### RG DS Plus

`make player-rg-ds-plus` cross-builds `build/mono-retro-player-rg-ds-plus` using
the existing ARM64 compiler configuration and target libraries in
`build/arm64-libs/`. It includes the DRM backend and needs target libudev,
libevdev, libdrm, OpenSSL and ALSA-enabled OpenAL Soft. No X11 libraries are required.
The cross-link directory must also contain OpenAL's target C++ runtime and its
matching libc/libm dependencies; the linker uses it for transitive dependencies
without embedding device-library paths into the executable.

Device detection reuses the tester's profiles; `--device:rg-ds-plus` and
`--display:drm` are available as overrides. Anbernic controls use the existing
app-owned Paddy mappings. The game starts on DSI-2 (bottom), with DSI-1 black.
L2 moves it between screens without restarting the core. Only the active screen
is redrawn; scaling stays at integer factors. Hold Select+Start for two seconds
to save and exit to the launcher.

#### Lost in Blue

The `rg-ds-plus-rocknix` device profile supports the source-built 7.0.2 kernel:
`retrogame_joypad` controls, standard left-stick axes, Goodix touch and RK817
battery reporting. Automatic detection requires the Plus device-tree identity,
controller and two DSI outputs. `--device:rg-ds-plus-rocknix` is an explicit
override. Vendor profiles remain separate; monorig selects the appropriate
network/audio setup for the running kernel.

`--ds-layout:separate` presents the DS top screen on DSI-1 and touch screen on
DSI-2. Each 256×192 image fills its 1024×768 panel at exactly 4× integer scaling.
Windy's native touch contacts supply the stylus; the first finger stays selected
until release or cancellation. L2 does not swap physical screens in DS mode.

Build the software-rendering ARM64 core with the same cross compiler used for
the player:

```sh
export MONO_RETRO_CC=/path/to/aarch64-unknown-linux-gnu-gcc
make core-melondsds-rg-ds-plus
make player-rg-ds-plus
```

The core target needs CMake, Make, Git and the matching cross G++ compiler. It
checks out melonDS DS 1.2.0 at `33c48260402865ef77667487528efd5ca7ce1233` under
ignored `build/sources/`. Upstream's CMake fetches its pinned melonDS,
libretro-common, embed-binaries, GLM, zlib, libslirp, pntr, fmt, yamc, span-lite
and date sources. The build enables ARM64 JIT and threaded software rendering,
disables OpenGL and release LTO, and targets Cortex-A55. `CORE_JOBS` defaults
to 8. No Nix runtime paths are embedded. Build outputs include
`build/cores/melondsds-arm64/src/libretro/melondsds_libretro.so` and the
upstream-generated combined attribution file `melondsds-LICENSE.txt` and
`SOURCES.txt` recording resolved dependency commits. Full dependency commits
are pinned in `tools/melondsds-revisions.cmake`.
The source checkouts must remain available for license/source provenance;
ROMs, saves, source downloads and compiled cores stay outside Git.

The handheld wrapper uses an independent
`/var/lib/mono-retro/saves/melonds-lost-in-blue/` directory and a copied
`LOST_IN_BLUE_ASKEA4_00.nds` under `/var/lib/mono-retro/roms/`. Its initial
`.srm` is a real copy of the archived original 8 KB `.sav`, separate from the
PC working save and stock Anbernic saves/states. Installation never reseeds an
existing test save. Built-in FreeBIOS/firmware avoids needing a user BIOS dump.
Full-speed emulation is not an acceptance requirement for this initial port.

### Launcher integration

On both devices the Decompbound menu entry invokes `/usr/local/bin/mono-retro-decompbound`, which
selects the core in `/usr/local/lib/libretro/`, ROM
`/var/lib/mono-retro/roms/EarthBound.smc`, separate device saves under
`/var/lib/mono-retro/saves/decompbound/`, and the app-specific OpenAL configuration
`/etc/mono-retro/alsoft.conf`. Monorig's secret-free handheld launcher tool manages
the wrapper and configuration. The launcher releases displays and input before
running the child and recreates them after it exits. Only one display application
may own the device at a time.

When `/usr/local/bin/mono-retro-lost-in-blue` exists, Lost in Blue appears after
Decompbound. Monorig installs this wrapper only on the RG DS Plus; it selects
`/usr/local/lib/libretro/melondsds_libretro.so`, the independent save directory,
`--ds-layout:separate` and the existing OpenAL configuration. The launcher's
`--lost-in-blue:PATH` override also supports isolated integration tests.

## Audio

Sound is enabled by default. Both libretro callbacks copy signed 16-bit stereo
PCM before returning to the core. After each emulated frame, the player passes
the combined samples to Slappy's `StreamingSource` at the core's reported sample
rate. All Slappy calls stay on the application's main thread, outside C callbacks.
OpenAL performs the playback and any output-rate conversion internally.

Playback primes with at least 30 ms of samples. Completed buffers are reclaimed
while polling events, and queued PCM is capped at 100 ms. If it exceeds that
limit, stale buffers are discarded and playback primes again. This queue bound
excludes buffering inside OpenAL and the operating system; it is not an
input-to-sound latency guarantee. The FPS clock controls emulation, retaining up
to two frames of timing debt so short delays can catch up; longer stalls reset
the deadline. There is no audio-driven clock or adaptive rate correction.
Exit logs report audio underruns (the source ran dry) and overruns (queued audio
exceeded the cap), excluding intentional pause/reset operations.

Focus loss or minimization flushes queued audio; resuming primes with fresh
samples. A changed core sample rate recreates the stream. Closing releases the
source and buffers before destroying the OpenAL context.

Slappy selects its first available OpenAL output. Backend/device selection is
handled through OpenAL Soft's normal configuration; volume uses the shared profile-configured system mixer.
Audio initialization and playback errors stop the player through its normal
save/cleanup path. Add `--mute` to deliberately discard audio without opening a
device. OpenAL Soft remains a linked runtime dependency in muted mode.

## Saves

Each game uses `<ROM-stem>.srm` inside the required `--save-dir`. The core's
system/BIOS directory is its `system/` child. mGBA's built-in GBA BIOS works
without a BIOS file. Paths remain valid for the loaded core's lifetime.

The first Mother 3 test uses a fresh save directory. Existing collection saves
are never imported automatically. Dirty save RAM is written every five seconds
and on orderly exit, through a flushed/fsynced temporary file and atomic rename.
An existing save larger than the core's reported capacity is rejected without
replacement. Smaller saves are accepted because mGBA can refine its detected
save capacity after boot. Core exports and callback failures are checked before
continuing; callback errors are raised after control returns to Nim.

Different ROMs with the same stem need separate save directories. Use one player
per save directory. Forced termination or power loss can lose changes since the
last successful write. Save states use the pause menu described below. RTC persistence and
cross-emulator save conversion remain outside this MVP.

## Performance diagnostics

See the [performance roadmap](docs/player-performance.md) for measured limits,
native-format transport, display-plane/GPU presentation and audio scheduling ideas.

Cooperating cores can negotiate an [opaque XBGR8888 extension](docs/libretro-extensions.md)
to pass Pixie-compatible pixel bytes without channel conversion. The frontend
copies padded rows into owned images; scaling and presentation keep their existing
behavior. Rejected format proposals return false and preserve the active format,
allowing standard XRGB8888 fallback. Existing cores need no changes.

`make benchmark-core` (or `make benchmark-core-arm64`) builds an uncapped,
headless benchmark using the same loader and state-import path as the player:

```sh
build/benchmark-core --core:PATH --rom:PATH --save-dir:DISPOSABLE_DIRECTORY \
  --load-state:SCREENSTATE --earthbound-ds --frames:600
```

Core rendering and audio generation remain enabled. The default discards their
output; `--copy-video` includes the frontend's normal video conversion but still
opens no display or audio device. Initialization is excluded from the reported
mean frame time. Always use a disposable save directory: SRAM is saved on exit.
For finite full-player runs, add `--no-input` to feed neutral controls to the
core while keeping exit shortcuts active. The headless benchmark also feeds
neutral controls by default. This prevents physical input from changing the test workload.
Standing still can hide rendering costs. For a moving EarthBound comparison,
compile either program with `-d:playerWalkBenchmark`: it alternates right/left
every 30 frames, ignores physical game input and requires a finite player run.
Use the same imported state and disposable saves for each comparison. Short
walking tests should remain within ten seconds; 480 frames take eight seconds
at 60 FPS. Walking mode cannot be combined with `--no-input`.

`make player-timings-rg-ds-plus` builds the full player with optional stage timers.
It accepts the normal player arguments and reports exclusive milliseconds per
emulated frame plus loop elapsed and CPU times on exit. `CoreWork` excludes the
separately reported video/audio capture callbacks. Stage wall times include
waits; Linux Nim `cpuTime` counts the calling thread. The separate process counter
uses `CLOCK_PROCESS_CPUTIME_ID` to include workers. Timers compile out of normal
builds. `make player-walking-rg-ds-plus` adds bounded walking input for matched
`--video:cpu`/`--video:auto` comparisons.

The XRGB8888 conversion uses ARM64 NEON where available and a scalar loop elsewhere,
retaining padded and unaligned row support. Scaling clears only black borders
before overwriting the image interior, reducing memory traffic. Native dual-screen playback compares each panel with its
last displayed pixels and retains unchanged scanout, avoiding redundant scaling
and uploads. Changed pixels and resized outputs redraw. X11 GPU retains unchanged
textures and redraws for crop changes, resize and restoration of hidden windows.

## Validation

Capture coverage includes synthetic checkpoint/export/import round-trips, sparse
inputs and pointer changes, duplicate and prefetched video, writer failures, and
F12/periodic/exit capture through real X11 events on a private Xvfb display.
For a local Decompbound core and ROM, run this headless check inside the player
Nix shell (it generates/captures PCM without opening an audio device):

```sh
nim r tests/integration_decompbound_capture.nim CORE_SO ROM_PATH SCREENSTATE_PNG
```

It records 60 dual-screen frames, checks every replayed pixel/PCM hash and the
final serialized machine state, then resumes the manual capture. Its temporary
captures are removed afterward. User-provided ROMs and screenstates stay outside Git.

```sh
make check test test-player
make test-player-x11
MONO_RETRO_TEST_VIDEO=gpu make test-player-x11
```

Set `MONO_RETRO_LEGACY_PLAYER` to an older player executable when running the
X11 integration test to additionally verify private-format rejection and
standard XRGB8888 fallback against that host. The normal suite checks the new
private format, colour readback, duplicates and dual-screen presentation.

The integration test starts its own isolated Xvfb by default, or accepts an
existing isolated server via `MONO_RETRO_TEST_DISPLAY`. It never selects the
user's desktop automatically. CPU is the default test path; the GPU run uses
software Mesa and `--vsync:off` because Xvfb has no physical refresh to synchronize.
Tests disable achievements and use temporary saves. They check displayed pixels, letterboxing on resize,
keyboard events, focus pause, save files and clean Escape/SIGTERM exits. Automated
audio playback uses OpenAL Soft's null backend, so tests do not play sounds on
the desktop. The X11 test also checks initialization failure cleanup and muted
playback with an unusable audio backend.
The C fixture also tests full-path versus in-memory ROM loading, option defaults,
duplicate frames, callback error containment, both captured-audio callbacks,
save reload/size checks and cleanup after rejected cores or ROMs.

The X11 suite also checks both DS window modes with a synthetic core: screen
separation, independent resize, letterboxing, pointer coordinates/drag/release,
focus transfer, keyboard input and either-window close. For the real core and
the separate Lost in Blue working files, run within the development shell:

```sh
nim r -o:build/integration-player-melonds tests/integration_player_melonds.nim \
  build/cores/melondsds-package/lib/retroarch/cores/melondsds_libretro.so \
  build/player-test/melonds-lost-in-blue/LOST_IN_BLUE_ASKEA4_00.nds \
  build/player-test/melonds-lost-in-blue/saves/LOST_IN_BLUE_ASKEA4_00.srm
```

This checks 600 frames of real DS graphics/audio and seed/save restoration using
temporary SRAM copies. Passing the same three paths to `integration_player_x11`
on an isolated display checks 180 paced real-core frames in each layout, with
OpenAL's null backend. Manual acceptance still needs original-save recognition,
touch accuracy in the game, audible playback and an in-game save/relaunch check.

With separately obtained mGBA and Mother 3 working copies:

```sh
nim r -o:build/integration-player-mgba tests/integration_player_mgba.nim \
  build/cores/mgba_libretro.so 'build/player-test/Mother 3 (English v1.3).gba'
build/integration-player-x11 \
  build/cores/mgba_libretro.so 'build/player-test/Mother 3 (English v1.3).gba'
```

The core smoke test runs 1,800 frames, checks 240×160 game graphics and captured
audio, then verifies save reload using temporary saves. It writes an ignored
capture to `build/player-test/mgba-smoke.png`. The optional X11 smoke test checks
180 paced frames. Neither is a substitute for manually playing, testing a real
controller and saving/loading in Mother 3's own menu. For audio acceptance, listen
for correct music speed/pitch and clean effects, then unfocus/refocus the window
and check that old audio does not resume.

## Handheld volume and pause menu

On RG DS Plus ROCKNIX, the volume buttons control shared speaker volume in the
launcher and player, with a brief on-screen percentage/bar. Menu/Home or F1 opens
Resume, Save State, Load State, Achievements and Exit to Launcher. Each game has
ten screenshot-backed save slots; Load State also browses recent resumable
captures. See [controls and save slots](docs/handheld-controls.md) and
[manual verification](docs/human-verify.md).
