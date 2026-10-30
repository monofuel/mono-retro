# mono-retro

Native Nim tools for retro handhelds and X11 desktops. `hwtest` uses Windy for
display and multitouch, Paddy for gamepads, raw evdev for diagnostics, and ALSA
for sound. See [Windy builds and backend selection](README-windy.md). Images and machine configuration belong in
monobake and monorig.

`mono-retro-player` runs libretro cores on X11 and the handhelds, including
melonDS DS with native dual-screen touch on the RG DS Plus.
See [building, controls and save handling](README-player.md).

RetroAchievements support adds Casual achievements for Decompbound, unlock popups
and a paused achievement browser. See [setup and controls](docs/retroachievements.md).

## Launcher

`mono-retro` has Hardware Test, System Info, Reboot, Shut Down and Decompbound entries. It uses Windy,
Pixie and Paddy, sharing the tester's device profiles and app-owned mappings.
The primary screen has a battery percentage/status toolbar. On DS Plus the
menu stays above while details, touch actions and System Info appear below.
Lost in Blue appears after Decompbound when its launch wrapper is installed.

Use D-pad/stick or keyboard arrows to select, physical A/Enter to open, and
B/Back/Escape to return. The information page scrolls with D-pad/stick, mouse
wheel or a bottom-screen drag. Mouse clicks select rows; the Open button
activates the selection. Escape at the desktop menu closes the launcher.

Reboot and Shut Down open a confirmation with Cancel selected initially. Use
D-pad/stick/arrows to choose, then A/Enter, or touch/click the confirmation
button. B/Back/Escape cancels. Power requests use normal OS commands, without
privilege escalation. RG SP power controls require unplugging its charger to
avoid the vendor kernel's known shutdown quirk. Failed requests remain visible
in the menu; an accepted request shows progress until the OS stops the service.

Hardware Test releases the launcher's displays and input handles before
starting the sibling `mono-retro-hwtest` process. Hold Select+Start in the
tester to return to the menu. `--tester:PATH` selects another executable.
There is no battery overlay over the separate diagnostic application.

Decompbound uses the same child-process handoff through the sibling
`mono-retro-decompbound` wrapper (`--decompbound:PATH` overrides it). Hold
Select+Start in the player to save and return. See [the player instructions](README-player.md#rg-ds-plus).

Build both applications with `make launcher-desktop`, or cross-build with
`make launcher-handhelds`. The latter creates `build/mono-retro-arm64` and
`build/mono-retro-hwtest-arm64`. Install them as `/usr/local/bin/mono-retro`
and `/usr/local/bin/mono-retro-hwtest`. Existing tester build targets remain.
Build desktop and cross targets sequentially.

The font is embedded; no system font installation is needed. Battery percentage
sources are profile-owned (`batterySupply`): axp2202 on SP and cw2015 on DS Plus.
The toolbar separates "Plugged in" from charging state. When external power is
connected but battery current is negative, it shows "Battery draining" in amber.
System Info explains the power deficit and shows signed battery current in mA.
DS Plus uses `batteryCurrentSupply: "battery"` for RK817 current while retaining
CW2015 percentage. A missing or invalid explicitly configured current source
shows "Charge state unknown". Without an explicit source, the selected gauge's
current is used when available, otherwise its reported status; the RG SP vendor
driver exposes no battery current, so it uses reported status.
System Info shows all reported gauges separately. Telemetry reads local
`/proc`, `/sys`, OS-release and `ip -j address show`; no network service,
credentials or router access is involved. Invalid readings remain unavailable.

The secret-free monorig tool `tools/handheld_launcher.nim rg-sp` (or
`rg-ds-plus`) emits the guarded OpenRC installation script. Run it through
the existing SSH connection using `sudo bash -s`. It enables the launcher in
the default runlevel, independently of networking. Stop/start it with
`sudo rc-service mono-retro stop` / `start`; logs are `/var/log/mono-retro.log`.
Before deployment, preserve existing binaries and service files. To roll back,
stop/disable the service and restore those saved files. This does not rebuild
the disk image or change Wi-Fi configuration.

## Build and tests

Applications use the shipping profile by default: speed optimization with
compiler runtime checks disabled (`danger`), including library release paths.
For checked developer builds with stack traces, use `-d:debug`, for example
`nim c -d:debug -o:build/mono-retro-player-debug src/player.nim`.
Tests are checked by default; `-d:danger` explicitly tests shipping behavior.
Explicit input validation and normal exceptions remain enabled in both profiles.

Requires Nim 2.x, a C compiler, Linux development headers, OpenSSL, libudev, libevdev
and make. The sibling Paddy checkout's `anbernic-handhelds` branch supplies the
automatic mdev discovery support. Register both checkouts in the parent Nimby workspace:

```sh
cd ..
nimby install paddy/paddy.nimble
nimby install mono-retro/mono-retro.nimble
cd mono-retro
```

Then build and test:

```sh
make check test build
build/hwtest --help
build/hwtest --device:rg-sp --preview:build/sp-preview.ppm
build/hwtest --device:rg-ds-plus --preview:build/ds-preview.ppm
```

The DS preview also writes `ds-preview-touch.ppm`. Previews need no hardware.
`make arm64` cross-compiles using `aarch64-unknown-linux-gnu-gcc` on PATH.
`MONO_RETRO_CC` selects another compatible compiler executable. Target settings
live in `config.nims`; the ARM64 binary uses the standard Linux loader.
Target libudev/libevdev libraries can be placed in `build/arm64-libs` for linking.
Direct handheld hardware access normally requires root; X11 windows do not.

ALSA playback loads `libasound.so.2` when first requested. DRM displays load
`libdrm.so.2` at runtime; framebuffer devices do not need libdrm. Gentoo packages
are `media-libs/alsa-lib` and `x11-libs/libdrm`. No audio daemon is needed.
`make test-audio` checks streaming against ALSA's silent null/file plugins
without accessing a speaker. It requires the ALSA shared library on the host.

## Device selection

The app automatically selects a built-in profile for the RG SP or RG DS Plus.
Detection combines board compatibility strings, input names and display
geometry/connectors rather than identifying every H700 or RK3568 board as an
Anbernic. Unknown hardware uses generic settings. Profiles remain available
for explicit overrides:

```sh
sudo build/hwtest info
sudo build/hwtest test --seconds:900
sudo build/hwtest test --profile:profiles/rg-ds-plus.json --seconds:900
```

On a configured handheld, use `sudo mono-retro-hwtest test --seconds:900`.
`--device:rg-sp`, `--device:rg-ds-plus` or `--device:generic` override detection.
An explicit JSON profile overrides the selected built-in profile; CLI options
then override both.

## Screens and controls

Both devices show colour bars, a grayscale ramp, an edge border, a moving
refresh marker and input indicators. Cyan means held; green means tested.
Each D-pad direction has its own tested state. Input names rather than event
numbers identify mapped controls. Generic profiles display raw Linux codes;
those labels do not imply a physical button layout.

RG SP uses `/dev/fb0` through the existing packed truecolor framebuffer path
(16-, 24- and 32-bit pixel formats). Its 17-button profile comes from physical
calibration.

RG DS Plus uses Windy's native DRM/KMS backend with CPU-drawn scanout buffers,
preferring a Pixie-compatible pixel format advertised by the primary plane.
It does not require a GPU renderer. DSI-1 is the top screen and DSI-2 is the
bottom, both 1024x768. The top shows buttons and the single left stick. Back
and Menu are distinct inputs. The bottom shows touch coordinates, finger IDs,
a trail and nine targets which turn green when touched. X clears the trail.
Touch samples commit at evdev report boundaries; multitouch contacts are
tracked independently. The kernel advertises extra controller axes/buttons
which need not correspond to physical controls.

Gamepad testing defaults to Paddy. All mapped gamepad badges, the Start tone,
X touch-clear action and Select+Start exit combo use Paddy's snapshots and
edges. The display reports the number of connected Paddy controllers; missing
controllers do not silently fall back to raw gamepad input. Back and volume
remain raw evdev inputs, marked `RAW`, and displayed touch contacts come through Windy's evdev backend.

Anbernic mappings belong to this app, in `src/retro/anbernic.nim`. It translates
Paddy's generic snapshots using its public `Gamepad` fields and accessors;
Paddy itself contains no Anbernic profiles. Other controllers pass through
unchanged. This app's mapped A/B/X/Y follow Xbox positions, while badges show
the handheld's printed legends: B is mapped A, A is mapped B, Y is mapped X and
X is mapped Y. App-mapped changes use an `APP` log prefix, Paddy connections
use `PADDY`, and kernel events use `RAW`.

The DS Plus stick shows a white app-mapped marker and a cyan raw evdev marker,
with both sets of coordinates. Paddy retains its normal 10% axis cutoff;
the app maps positive Y to point up. Raw coordinates are scaled linearly and clamped
only at the panel edges, without an application deadzone or smoothing.
Controller firmware or kernel-driver filtering can still affect both.

Use `--gamepad:raw` for the original raw test, including raw gamepad badges,
tone and exit actions. Calibration always reads raw evdev events.

The test polls input every 8 ms and redraws on an 80 ms timer, writing its scanout buffer directly;
it is a functional hardware test, not a vblank-paced latency benchmark.

## Sound and exit

Sound plays only on a fresh Start press in test mode. Holding Start does not
repeat it. The quiet, faded test is 440 Hz on the left, then 660 Hz on the right.
A mono speaker mixes those channels. After the first press, a worker keeps the
PCM open and writes silence between tones, avoiding repeated codec power
transitions. Hold Select+Start for two seconds to exit, or interrupt via SSH
with Ctrl+C. Tests also stop after the selected duration. The explicit `audio`
command plays one tone immediately for manual diagnostics.

monorig installs named ALSA PCMs which temporarily enable speaker routing and
restore mixer controls when playback closes, without replacing the system's
default PCM. RG SP uses `mono_retro_test` on `audiocodec`; DS Plus uses
`mono_retro_ds_plus` on `rockchipaw883xx`. DS Plus also requires the stock
`aw883xx_acf.bin` speaker firmware before boot, installed by monobake from the
verified stock backup. If adding it to an already booted system, reboot;
the stock amplifier driver has an unsafe runtime unbind/rebind path.

The app observes input without an exclusive grab and does not handle power or
lid actions. Other software can still react to the same buttons. Do not run
multiple display tests at once. `info` queries display geometry without
changing scanout.

On normal exit, SIGINT and SIGTERM, fbdev memory/offsets are restored. DRM
restores retained original framebuffers and connector routes; if the vendor
kernel retired its boot-logo framebuffer, the test output is disabled instead.
Returning to the boot splash is not guaranteed. SIGKILL/power loss cannot run
cleanup.

## Profiles and calibration

Profiles use JSON: `title`, `display` (`auto`, `x11`, `fbdev`, `drm`), `framebuffer`,
`drmDevice`, ordered `outputs`, `inputNames`, `audioDevice`, `rotation`,
`toneKey`, `bindings`, `sticks`, `touchName` and `touchRotation`.
Rotations accept 0/90/180/270. Stick entries contain `label`, `device`, `x`
and `y` (evdev absolute-axis codes). Bindings contain a physical label, input
device name, Linux event kind/code and direction.

`--fb`, repeatable `--input`, `--pcm`, `--rotate`, `--display`, `--drm`,
repeatable `--output` and `--touch-rotate` override profile settings. The first
output override replaces the profile's output list. For another panel order:

```sh
sudo build/hwtest test --device:rg-ds-plus --output:DSI-2 --output:DSI-1
```

To build a physical button mapping, start with a profile selecting the
appropriate input names:

```sh
sudo build/hwtest calibrate --profile:profiles/device.json --save-profile:/tmp/device-mapped.json
```

Press and release the named controls: D-pad, A/B/X/Y, L/R, Select/Start, Menu,
volume down/up and L2/R2, plus Back for a touch profile. Existing bindings are
retained; only missing labels are requested. Remove a binding from the input
profile to remap it. Calibration plays no sound. A completed mapping is written
to the selected output and the app enters test mode. A timeout or interruption
leaves the existing output unchanged. Analog-axis and touch transforms remain
profile settings rather than part of button calibration.
