# mono-retro-player

A silent desktop libretro player using Nim, Windy, Pixie and Paddy. The first
target is Mother 3 with mGBA on X11. It runs independently of the launcher;
handheld display backends, audio playback, save states and menus are future work.

## Build and run

Use Nim 2 and Nimby with the project's existing dependencies. The current
Windy and Paddy `anbernic-handhelds` branches supply the APIs used here; no
player-specific library changes are required. Native Linux dependencies are
libudev, libevdev, libX11 and libXcursor, plus a C compiler for the ABI bridge.

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

Emulation pauses while the window is unfocused or minimized. On resume the
clock starts from the current time. Frames follow the core's reported rate
(mGBA reports about 59.73 Hz), without burst catch-up. The software renderer
copies pitch-aware RGB565, XRGB8888 or 0RGB1555 frames, repeats duplicate frames,
and scales with nearest-neighbour sampling inside black borders. Hardware
rendering requests are unsupported. The window starts at 720×480 and resizes.

Audio emulation remains enabled, but both audio callbacks discard samples;
no audio device or audio library is opened. `--frames:N` exits after N emulated
frames for bounded tests. Window close, SIGINT and SIGTERM also save and exit.

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
keyboard events, focus pause, save files and clean Escape/SIGTERM exits.
The C fixture also tests full-path versus in-memory ROM loading, option defaults,
duplicate frames, callback error containment, both discarded-audio callbacks,
save reload/size checks and cleanup after rejected cores or ROMs.

With separately obtained mGBA and Mother 3 working copies:

```sh
nim r -o:build/integration-player-mgba tests/integration_player_mgba.nim \
  build/cores/mgba_libretro.so 'build/player-test/Mother 3 (English v1.3).gba'
# While an isolated Xvfb is running:
MONO_RETRO_TEST_DISPLAY=:97 build/integration-player-x11 \
  build/cores/mgba_libretro.so 'build/player-test/Mother 3 (English v1.3).gba'
```

The core smoke test runs 1,800 frames, checks 240×160 game graphics and discarded
audio, then verifies save reload using temporary saves. It writes an ignored
capture to `build/player-test/mgba-smoke.png`. The optional X11 smoke test checks
180 paced frames. Neither is a substitute for manually playing, testing a real
controller and saving/loading in Mother 3's own menu.
