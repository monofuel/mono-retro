# mono-retro-player

A libretro player using Nim, Windy, Pixie, Paddy and Slappy. Targets include
Mother 3 with mGBA on X11, decompbound on both handhelds and melonDS DS on X11
and the RG DS Plus. The player
can run independently or as a child of the launcher. Existing core-defined states
can be imported; state creation and ROM browsing are future work.

## Build and run

Use Nim 2 and Nimby with the project's existing dependencies. The current
Windy and Paddy `anbernic-handhelds` branches supply the APIs used here; no
player-specific library changes are required. Native Linux dependencies are
libudev, libevdev, libX11, libXcursor and OpenAL Soft, plus a C compiler for the
ABI bridge. Install Slappy ≥0.4.0 and its dependencies through Nimby in the
existing parent workspace, preserving the Windy/Paddy branches.

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
`--load-state` on handhelds. The player does not create states or register state
hotkeys, and cores with no state support still work normally without this option.

## Controls

| Input | GBA action |
|---|---|
| Arrow keys | D-pad |
| X / Z | A / B |
| A / S | L / R |
| Enter / Backspace | Start / Select |
| Escape | Save and exit |

The first connected Paddy controller (lowest device ID) maps physical RetroPad
positions: east is A, south is B, north is X and west is Y; shoulders are L/R.
The left stick also supplies eight-way D-pad input past half travel on either
axis. Digital D-pad input takes precedence on the same axis. The right stick
does not move the D-pad. Keyboard and controller buttons
combine. Unplugging the controller removes its held buttons. Device-specific
mapping remains an application concern.

Desktop emulation pauses while the window is unfocused or minimized. On resume the
clock starts from the current time. Frames follow the core's reported rate
(mGBA reports about 59.73 Hz), recovering up to two frames of timing debt before
resetting after a longer stall. One dedicated thread owns the software core and
its callbacks, including initialization, saves and state imports. It computes at
most one frame ahead while the main thread handles input, audio and presentation.
Frame buffers transfer ownership between threads; duplicate video callbacks retain
the displayed image. This overlap avoids adding display work to the emulation
thread's frame budget. The software renderer
copies pitch-aware RGB565, XRGB8888 or 0RGB1555 frames, repeats duplicate frames,
and scales by the largest whole-number factor that fits (1×, 2×, 3×, …), centered
inside black borders. Pixels stay square; the core's display-aspect hint does not
stretch the image. The window starts at the core's native base resolution (for
example, 240×160 for GBA). Below native size, the image remains at 1× and is
center-cropped. Hardware rendering requests are unsupported.

DRM playback requests synchronized presentation from Windy's `anbernic-handhelds`
backend. Each screen uses two buffers and switches at vblank, avoiding writes
into the currently visible buffer. Uploads wait for the previous switch before
reusing its storage; the frame clock still sets the emulation rate. This requires
the fork's DRM page-flip support. X11 and fbdev retain their existing presentation.

`--frames:N` exits after N emulated frames for bounded tests. Window close,
SIGINT and SIGTERM also save and exit.

## EarthBound DS companion

With decompbound's dual-screen core, add `--earthbound-ds` to the normal player
command. This preset enables `decompbound_dual_screen=enabled` and requires a
256×448 software frame: two stacked 256×224 panels. It cannot be combined with
`--ds-layout`, which retains its melonDS-specific options and geometry.

On X11, **Game** and **Party** windows start at 512×448 (2×) and resize
independently. On the RG DS Plus, use the ordinary `player-rg-ds-plus` build
with `--device:rg-ds-plus --earthbound-ds`; Game goes to DSI-1 and Party/touch
to DSI-2. Both panels use the existing integer scaling and centering. On
1024×768 displays the panels are 768×672 (3×) with black borders. EarthBound DS
targets 2× and above; original DS-size 1× layouts are outside its MVP.

The core draws party HP/PP and browsable inventory. Tap/click a card or use
**L2/R2** (**Page Up/Page Down** on keyboard) to choose a character. These
triggers reach the core instead of swapping physical displays. Gameplay
controls keep working; item use and battle commands remain in the game menus.
Only lower-panel touches inside the scaled image reach the companion. The
existing first-contact touch policy, focus pause, audio, SRAM persistence and
either-window exit behavior apply.

Use a separate `--save-dir` for testing. The existing launcher entry and
installed handheld wrappers are unchanged. Decompbound's
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
libevdev, libdrm and ALSA-enabled OpenAL Soft. No X11 libraries are required.
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
handled through OpenAL Soft's normal configuration; volume uses system controls.
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
last successful write. Save states, RTC persistence and cross-emulator save
conversion are outside this MVP.

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
emulated frame plus loop elapsed time on exit. `CoreWork` excludes the separately
reported video/audio capture callbacks. Timers compile out of normal builds.

The XRGB8888 conversion uses ARM64 NEON where available and a scalar loop elsewhere,
retaining padded and unaligned row support. Scaling clears only black borders
before overwriting the image interior, reducing memory traffic. Native dual-screen playback compares each panel with its
last displayed pixels and retains unchanged scanout, avoiding redundant scaling
and uploads. Changed pixels and resized outputs redraw. X11 continues presenting
every frame so expose/focus/resize handling does not depend on retained scanout.

## Validation

```sh
make check test test-player
Xvfb :97 -screen 0 1600x1200x24 -nolisten tcp &
xvfbPid=$!
MONO_RETRO_TEST_DISPLAY=:97 make test-player-x11
kill "$xvfbPid"
```

Set `MONO_RETRO_LEGACY_PLAYER` to an older player executable when running the
X11 integration test to additionally verify private-format rejection and
standard XRGB8888 fallback against that host. The normal suite checks the new
private format, colour readback, duplicates and dual-screen presentation.

Use an unused isolated display large enough for the combined DS resize test
(778 pixels high); the integration test refuses to run without
`MONO_RETRO_TEST_DISPLAY`. It checks displayed pixels, letterboxing on resize,
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
# While an isolated Xvfb is running:
MONO_RETRO_TEST_DISPLAY=:97 build/integration-player-x11 \
  build/cores/mgba_libretro.so 'build/player-test/Mother 3 (English v1.3).gba'
```

The core smoke test runs 1,800 frames, checks 240×160 game graphics and captured
audio, then verifies save reload using temporary saves. It writes an ignored
capture to `build/player-test/mgba-smoke.png`. The optional X11 smoke test checks
180 paced frames. Neither is a substitute for manually playing, testing a real
controller and saving/loading in Mother 3's own menu. For audio acceptance, listen
for correct music speed/pitch and clean effects, then unfocus/refocus the window
and check that old audio does not resume.
