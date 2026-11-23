# Bluetooth

Open **Start → Settings → Bluetooth** in the game-library launcher. The same page
works with the RG DS Plus touchscreen, handheld controls and desktop keyboard.
This does not add Bluetooth to the older diagnostic-only menu.

Use **Y / Turn on** to power the adapter, then **X / Scan**. Choose a device and
**Pair and connect**, or **Connect** for a remembered device. PIN entry uses the
shared touchscreen keyboard; numeric comparisons default to Cancel. **B / Back**
cancels a pending pairing. **Forget** asks for confirmation before removing the
selected pairing. Scans stop after 20 seconds or when leaving the Bluetooth page.

The menu distinguishes a connected radio link from an available audio transport
or a controller that has actually appeared as a gamepad. No adapter, permission
failure, timeout or missing helper remains an explicit error. Existing pairings
are retained. Only the first local Bluetooth adapter is used.

## Headphones

Once **Headphone audio ready** appears, choose **Use for audio**. Output changes
apply to the next Player or Hardware Test launch. **Use speakers for new apps**
selects the normal device output again. Preferences are in the user's
`mono-retro/audio-output.json` under the XDG config directory, separate from the
games card, device profiles and theme preferences.

If selected headphones are unavailable when launching a game, the menu offers
**Retry**, **Use speakers**, or **Cancel**. Choosing speakers saves that explicit
choice. It never silently substitutes speakers. If headphones disconnect during
play, the game continues with playback muted until the next launch; the player
also reports the audio error in its log. Reconnecting does not automatically
resume playback in that running game.

Playback uses BlueALSA's ALSA PCM and mixer for the exact selected MAC address.
The initial scope is **SBC A2DP playback**, with separate remembered speaker and
per-headphone volume. No PulseAudio or PipeWire service is introduced. Existing
OpenAL capture settings and microphone gain remain unchanged; headset
microphones, HFP/HSP, codec selection and simultaneous outputs are outside this
version. Bluetooth audio latency is not measured by these tests.

## Controllers

Player one accepts the built-in handheld controller plus one external gamepad
(the lowest external Paddy ID). Either can control the game and pause menu.
Select+Start must be held on the **same** controller for two seconds to exit;
the built-in controls remain a recovery path after an external disconnect.
Desktop selection remains the first gamepad. This adds no new device mappings
to Paddy or shared input libraries. Unknown controller layouts still depend on
Paddy's generic Linux mapping.

## Installation

Build the sibling helper with `make launcher-desktop` or
`make launcher-handhelds`. Install `mono-retro-bluetooth` next to the launcher,
alongside its existing library, Wi-Fi and hardware-test helpers. Update the Player
and Hardware Test binaries too: older builds do not consume the output preference.
The backend requires the system libdbus-1 runtime; compiling it requires dbus-1
headers and pkg-config. A cross build must provide target headers through
`MONO_RETRO_DBUS_CFLAGS` and the target library through the normal SDK linker path.
It must not use host headers by accident.

The vendor-boot handheld profiles in **monorig** provision D-Bus, BlueZ and
BlueALSA, enable their OpenRC services, and add `monofuel` to `audio` without
replacing existing group membership. A new login picks up supplementary groups.
The profile restricts BlueALSA to `-p a2dp-source -c SBC -c -FastStream` and
disables optional codecs. It preserves `/var/lib/bluetooth`, network services,
ALSA defaults, credentials, boot files and existing Wi-Fi firmware.

If a pre-existing BlueALSA daemon had different options, finish any active audio
session before explicitly restarting **only BlueALSA** after provisioning. The
idempotent profile does not unconditionally restart an active audio daemon.
Do not restart D-Bus or replace the existing network stack.

For the DS Plus source-built kernel, the DT's RTL8821CS node includes the
`realtek,rtl8723bs-bt` compatibility string handled by the existing H5 driver.
The firmware savedconfig adds the RTL8821CS firmware/config and the config
symlink target while retaining Wi-Fi firmware. No kernel change is part of this
feature. **RG SP stock-kernel UART attachment still needs physical inspection**;
the profile does not guess a UART, baud rate or hciattach command.

## Validation and remaining hardware checks

Local checks cover private D-Bus exchanges with fake BlueZ/BlueALSA services,
real CLI stdin and atomic state files, prompt rejection/timeouts, cancellation,
controller selection, strict playback initialization, headphone disconnection,
volume persistence, and all four themes at 320×240, 640×480 and 1024×768.
The X11 integration test uses a separate test display and synthetic devices.
These fixtures do not establish working radios or headphone compatibility.

Both handhelds were offline during initial implementation. Installation,
actual pairing, PIN/passkey prompts, headphone audio/volume/disconnection,
controller hotplug and built-in recovery **remain hardware acceptance checks**.
Do not present the feature as physically validated until those checks pass.
Automated playback must use a verified null backend; manual tests use normal
audio. Preserve any running game or Grimoire session before installing/restarting.

## Implementation references

- [BlueZ Device API](https://bluez.readthedocs.io/en/latest/device-api/) and
  [Agent API](https://bluez.readthedocs.io/en/latest/agent-api/).
- [BlueALSA 4.3.1](https://github.com/arkq/bluez-alsa/tree/v4.3.1), including
  [ALSA PCM](https://github.com/arkq/bluez-alsa/blob/v4.3.1/doc/bluealsa-plugins.7.rst)
  and [system-bus policy](https://github.com/arkq/bluez-alsa/blob/v4.3.1/src/bluealsa.conf.in).
- [OpenAL Soft ALSA backend](https://github.com/kcat/openal-soft/blob/1.24.3/alc/backends/alsa.cpp).

`retro/bluetooth.nim` contains the secret-free state model;
`retro/bluezbus.nim` binds the documented system APIs through libdbus's real C
headers; `bluetoothcli.nim` owns the private bus and pairing agent. The launcher
runs that helper asynchronously via `retro/bluetoothworker.nim`. It never
requests default-agent ownership or parses `bluetoothctl` output.

Commands are newline JSON on the owned child's stdin. PIN/passkey values are
never command-line arguments or log messages. Mode-0600 atomic state snapshots
contain display prompts, never entered PINs, and carry the acknowledged request
number so a previous failure cannot cancel a new Retry. Child EOF/SIGTERM
cancels owned operations/discovery and unregisters its agent; established
connections remain managed by BlueZ. A dead bus is reported unavailable;
restarting the launcher/helper is required after a system-bus disconnect. BlueZ
service and adapter recovery is polled.
