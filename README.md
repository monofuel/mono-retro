# mono-retro

Native Nim tools for retro handhelds. `hwtest` tests screens, evdev buttons,
analog sticks, touch and ALSA sound without X11, Wayland or SDL. It has no
third-party Nim dependencies. Images and machine configuration belong in
monobake and monorig.

## Build and tests

Requires Nim 2.x, a C compiler, Linux development headers and make:

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
Linux hardware access normally requires root.

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

RG DS Plus uses native DRM/KMS with CPU-drawn, mapped XRGB8888 scanout buffers.
It does not require a GPU renderer. DSI-1 is the top screen and DSI-2 is the
bottom, both 1024x768. The top shows buttons and the single left stick. Back
and Menu are distinct inputs. The bottom shows touch coordinates, finger IDs,
a trail and nine targets which turn green when touched. X clears the trail.
Touch samples commit at evdev report boundaries; multitouch contacts are
tracked independently. The kernel advertises extra controller axes/buttons
which need not correspond to physical controls.

Analog markers use raw evdev values scaled linearly to the panel, clamped only
at its edges. Raw X/Y values are also displayed. The app applies no deadzone,
smoothing, averaging or cardinal snapping, including no application of the
kernel's advertised `flat` deadzone. Controller firmware or kernel-driver
filtering can still affect the values delivered through evdev.

The test redraws on an 80 ms timer and writes its scanout buffer directly;
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

Profiles use JSON: `title`, `display` (`auto`, `fbdev`, `drm`), `framebuffer`,
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
