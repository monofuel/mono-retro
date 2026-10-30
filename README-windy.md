# Windy handheld tester

The hardware tester uses [Windy](https://github.com/treeform/windy) for display
and multitouch, and [Paddy](https://github.com/treeform/paddy) for controller
discovery. Anbernic mappings remain in mono-retro.

Use the [Nimby workspace setup](README.md#build). The project's `nimby.lock`
pins the same Windy and Paddy forks for the tester, launcher and player.
The [hardware test guide](docs/hardware-test.md) covers controls, profiles,
calibration and audio diagnostics.

Run the build commands below from mono-retro. Cross builds require the existing
AArch64 compiler and target libudev/libevdev libraries; `MONO_RETRO_CC` selects
the compiler. Definitions and linker settings live in `config.nims`.

| Command | Included backends | Output |
| --- | --- | --- |
| `make desktop` | X11 | `build/hwtest-desktop` |
| `make rg-sp` | fbdev, AArch64 | `build/hwtest-rg-sp` |
| `make rg-ds-plus` | DRM, AArch64 | `build/hwtest-rg-ds-plus` |
| `make handhelds` | fbdev + DRM, AArch64 | `build/hwtest-handhelds` |
| `make combined` | X11 + fbdev + DRM, native architecture | `build/hwtest-combined` |
| `make combined-arm64` | X11 + fbdev + DRM, AArch64 | `build/hwtest-combined-arm64` |

The combined executable selects its backend with `--display:x11`,
`--display:fbdev` or `--display:drm`. Device detection selects the handheld
profile as before. Unknown hardware defaults to X11 when that backend was
compiled; direct-only builds default to their first available backend.
There is no retry through a different backend after initialization fails.
Combined builds require their included X11 client libraries even when running
on a handheld. A separate handheld build does not require X11 or GLX.

The RG SP opens one native-size window on `/dev/fb0`. The DS Plus opens
independent windows on DSI-1 and DSI-2 through one shared DRM device connection.
The selected profile supplies connector order and the touch device name, which
differ between stock and ROCKNIX kernels. Touch is assigned to the second
window. Windy applies scaling and touch rotation; the app draws window-local positions.
Touch contacts retain IDs and have begin/move/end/cancel phases. There is no
smoothing, gesture recognition or synthesized mouse input. X11 and browser
multitouch are future work.

The tester draws its original patterns, badges and targets directly into
Pixie images and calls `presentPixels`. Native presentation is
CPU based and updates scanout memory directly; it does not promise vblank
pacing or tear-free output. DRM selects a Pixie-compatible primary-plane format
when available and copies complete rows to mapped scanout memory. Other formats
convert in cached memory before copying. Windy's normal X11/OpenGL builds remain the default; the
tester's X11 build uses the new CPU pixel path.

Paddy handles gamepads; raw evdev input remains available for comparison,
calibration, volume and Back. Windy supplies the displayed touch contacts and
trails. ALSA playback is unchanged: Start requests a tone; holding Select+Start
for two seconds exits. On desktop, Escape or the window close button exits.
Desktop testing does not require a raw input device or root access, although
optional gamepads may require input-device permissions.

Only run one display application on a handheld. Candidate binaries are installed
as `/usr/local/bin/mono-retro-hwtest-windy`; earlier tester binaries are kept.
Normal exit, SIGINT and SIGTERM close the windows and restore available display
state. If the vendor boot-logo framebuffer has been retired, DRM disables that
output on exit instead of promising restoration of the splash.

`make check test test-audio` covers the app's diagnostics. Windy's Makefile
provides native input tests and X11 CPU/combined tests. Run X11 tests in an
isolated Xvfb display, not on the user's desktop. `tests/manual_direct_displays.nim`
in Windy checks repeated opening, independent screens, duplicate output rejection
and closing the first screen while continuing to draw on the second.
