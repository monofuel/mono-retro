# mono-retro

Native Nim tools for retro handhelds. The first application, `hwtest`, tests
Linux framebuffer output, evdev buttons/axes and ALSA sound without X11,
Wayland or SDL. It has no third-party Nim dependencies. Images and machine
configuration belong in monobake and monorig.

## Build and tests

Requires Nim 2.x, a C compiler, Linux development headers and make:

```sh
make check test build
build/hwtest --help
build/hwtest --preview:build/preview.ppm
```

`make arm64` cross-compiles using `aarch64-unknown-linux-gnu-gcc` on PATH.
`MONO_RETRO_CC` selects another compatible compiler executable. Target settings
live in `config.nims`; the ARM64 binary uses the standard Linux loader. Linux
hardware access normally requires root. ALSA playback loads `libasound.so.2`
from `media-libs/alsa-lib` when first requested; no audio daemon is needed.
`make test-audio` checks streaming against ALSA's silent null/file plugins
without accessing a speaker. It requires the ALSA shared library on the host.

## RG SP

The RG SP profile selects the framebuffer, input device names and named ALSA
PCM. monorig's handheld configuration installs `mono_retro_test`, whose ALSA
hooks temporarily enable the codec/speaker route and restore mixer controls
when playback closes. It does not replace the system's default PCM.

```sh
sudo build/hwtest info --profile:profiles/rg-sp.json
sudo build/hwtest test --profile:profiles/rg-sp.json --seconds:900
```

On the configured handheld the installed paths are:

```sh
sudo mono-retro-hwtest test --profile:/etc/mono-retro/rg-sp.json --seconds:900
```

The screen shows colour bars, a grayscale ramp, an edge border, a moving
refresh marker and input indicators. Cyan means held; green means tested.
Each D-pad direction has its own tested state. Input names rather than event
numbers identify mapped controls. Unmapped profiles display raw Linux codes;
those generic labels do not imply the physical button layout.

Sound plays only on a fresh Start press in test mode. Holding Start does not
repeat it. The quiet, faded test is 440 Hz on the left, then 660 Hz on the right.
A mono speaker mixes those channels. After the first press, a worker keeps the
PCM open and writes silence between tones, avoiding repeated codec power
transitions. Mixer settings restore when the app exits. Hold Select+Start for two seconds to exit,
or interrupt via SSH with Ctrl+C. Tests also stop after the selected duration.
The explicit `audio` command plays one tone immediately for manual diagnostics.
The test observes input without an exclusive grab and does not handle power or
lid actions. Other software can still react to the same buttons.

Framebuffer memory and scanout offsets are restored on normal exit, SIGINT and
SIGTERM. SIGKILL/power loss cannot run cleanup. Restoring framebuffer memory is
not a guarantee that the bootloader's independently retained splash returns.
`info` queries geometry without changing scanout. Do not run multiple display
tests at once.

## Other devices and calibration

Profiles use JSON: `title`, `framebuffer`, `inputNames`, `audioDevice`,
`rotation` (0/90/180/270), `toneKey`, and optional `bindings`. Command-line
`--fb`, repeatable `--input`, `--pcm` and `--rotate` override device settings.
The modules do not assume H700 geometry or pixel-channel order. The current
renderer supports packed truecolor 16-, 24- and 32-bit framebuffer devices.
Dual-screen devices can select a framebuffer with `--fb`; simultaneous screens,
DRM/KMS and touch are not implemented or validated on RG DS Plus.

To build a physical button mapping, start with a profile that selects the
appropriate input names, then run:

```sh
sudo build/hwtest calibrate --profile:profiles/device.json --save-profile:/tmp/device-mapped.json
```

Press and release the named controls: D-pad, A/B/X/Y, L/R, Select/Start, Menu,
volume down/up and L2/R2. Existing bindings are retained, and only missing
labels are requested. Remove a binding from the input profile to remap it.
Calibration plays no sound. A completed mapping is written to the selected
output and the app enters test mode. A timeout or interruption leaves the
existing output unchanged.

Bindings record device name, Linux event kind/code, axis direction and physical
label. This keeps one device's button numbering out of the application code.
The checked-in RG SP mapping comes from physical button calibration. Add a
separate profile when validating another device.
