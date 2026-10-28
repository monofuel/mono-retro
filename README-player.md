# mono-retro-player

A desktop libretro player using Nim, Windy, Pixie, Paddy and Slappy. The first
targets are Mother 3 with mGBA on X11 and decompbound on the RG SP and RG DS Plus. The player
can run independently or as a child of the launcher. Save states and ROM browsing
are future work.

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

## Controls

| Input | GBA action |
|---|---|
| Arrow keys | D-pad |
| X / Z | A / B |
| A / S | L / R |
| Enter / Backspace | Start / Select |
| Escape | Save and exit |

The first connected Paddy controller (lowest device ID) maps physical RetroPad
positions: east is GBA A, south is GBA B, shoulders are L/R. The D-pad is used;
analog stick conversion is outside this MVP. Keyboard and controller buttons
combine. Unplugging the controller removes its held buttons. Device-specific
mapping remains an application concern.

Desktop emulation pauses while the window is unfocused or minimized. On resume the
clock starts from the current time. Frames follow the core's reported rate
(mGBA reports about 59.73 Hz), without burst catch-up. The software renderer
copies pitch-aware RGB565, XRGB8888 or 0RGB1555 frames, repeats duplicate frames,
and scales by the largest whole-number factor that fits (1×, 2×, 3×, …), centered
inside black borders. Pixels stay square; the core's display-aspect hint does not
stretch the image. The window starts at the core's native base resolution (for
example, 240×160 for GBA). Below native size, the image remains at 1× and is
center-cropped. Hardware rendering requests are unsupported.

`--frames:N` exits after N emulated frames for bounded tests. Window close,
SIGINT and SIGTERM also save and exit.

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
core layout and pointer input. It requires 256×384 video and X11. Core option
overrides use the existing legacy libretro options API; unsupported requested
options fail explicitly. Our Windy fork includes the X11 event-predicate ABI fix
needed to route focus and mouse input independently between the two windows.

The tested cartridge boots with the core's built-in FreeBIOS and firmware.
Audio output uses Slappy as usual. Microphone input is disabled for this MVP;
Lost in Blue interactions requiring blowing remain unavailable. Handheld DS
presentation and switching layouts during play are deferred.

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

### Launcher integration

On both devices the Decompbound menu entry invokes `/usr/local/bin/mono-retro-decompbound`, which
selects the core in `/usr/local/lib/libretro/`, ROM
`/var/lib/mono-retro/roms/EarthBound.smc`, separate device saves under
`/var/lib/mono-retro/saves/decompbound/`, and the app-specific OpenAL configuration
`/etc/mono-retro/alsoft.conf`. Monorig's secret-free handheld launcher tool manages
the wrapper and configuration. The launcher releases displays and input before
running the child and recreates them after it exits. Only one display application
may own the device at a time.

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
input-to-sound latency guarantee. The existing FPS clock still controls emulation;
there is no audio-driven clock or adaptive clock-drift correction in this MVP.

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

## Validation

```sh
make check test test-player
Xvfb :97 -screen 0 1024x768x24 -nolisten tcp &
xvfbPid=$!
MONO_RETRO_TEST_DISPLAY=:97 make test-player-x11
kill "$xvfbPid"
```

Use an unused isolated display; the integration test refuses to run without
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
