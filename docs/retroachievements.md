# RetroAchievements

The player supports **Casual achievements for Decompbound**, with
unlock popups and a paused achievement browser. Real-account and handheld
acceptance remain manual; desktop synthetic tests do not establish either.
Other cores currently show achievements as unavailable. Hardcore mode is disabled.

## Sign in

Build the player using [the existing instructions](../README-player.md#build-and-run),
and build the account helper:

```sh
nim c -o:build/mono-retro-ra src/ra_auth.nim
build/mono-retro-ra login
build/mono-retro-ra status
build/mono-retro-ra logout
```

Login needs an internet connection and prompts for a username and hidden password.
HTTPS uses OpenSSL with certificate and DNS-name verification. It uses system
trust roots and honors `SSL_CERT_FILE` / `SSL_CERT_DIR` for an explicit CA bundle.
It stores only the returned username and token in `~/.mono-retro-ra.json`, written
atomically with owner-only permissions (`0600`). The password is not saved.
`status` reads local configuration without connecting or displaying the token.
`logout` deletes the local file; restart an already running player to apply it.
Keep this file out of Git and screenshots.

The helper and player both accept `--ra-config:/absolute/path/to/file.json`.
For a launcher running as root, pass that option explicitly in the **player's
launch wrapper**, using the same protected file configured by the helper.
Otherwise the root process looks in its own home, usually `/root`, rather than
your desktop account's home. Do not put passwords or tokens in command arguments.

Achievements default to on and start automatically when the core is supported
and credentials are configured. Missing or rejected credentials leave gameplay
available with a status message. Disable evaluation with `--achievements:off`.

## Controls

| Action | Keyboard | Paddy / handheld |
|---|---|---|
| Open or resume | F1 | Menu / Home |
| Select a row or scroll details | Up / Down | D-pad Up / Down |
| Change page | Left / Right | D-pad Left / Right |
| Open details / return to list | Enter | A |
| Back from details / close browser | Escape | B |

Mouse and touch can select the browser's rows and buttons. Escape outside the
browser still exits the player. Opening the browser pauses emulation and clears
queued audio/input. SDK callbacks continue while paused. Dual-screen layouts keep
the frozen game above the browser; closing restores the original game/party view.
Short unlock popups appear during play.

## Network and state behavior

Startup needs online authentication, ROM identification and achievement definitions;
there is no persistent offline definitions cache. If startup fails, restore the
connection and restart the player. After a successful startup, the SDK retries
temporary submission failures while the same session remains open, including
while the browser is paused. There is **no persistent submission queue**: closing
the app does not preserve pending submissions for the next launch.

Successful legacy state imports reset achievement hit counts/deltas using the
SDK's null-progress restore and refresh exported memory pointers. Existing
account unlocks remain earned. A rejected import preserves the running achievement
state. Startup state imports happen before achievement initialization. RA progress
is not embedded in Decompbound screenstates or used to change their format.

## Implementation

The frontend vendors unmodified MIT-licensed **rcheevos 12.5.0**, pinned to
[`1433173220a7eaede6a9ed7a18e94117be1821e0`](https://github.com/RetroAchievements/rcheevos/tree/1433173220a7eaede6a9ed7a18e94117be1821e0).
See [the vendor record](../third_party/rcheevos/README.md) and
[license](../third_party/rcheevos/LICENSE). Definitions and account data come from
the service at runtime; game assets, credentials and achievement sets are not bundled.

The emulation worker owns the SDK and evaluates it after every emulated frame,
including duplicate video callbacks. A separate HTTPS worker transfers owned
requests/responses; it never reads core memory or calls the SDK. UI replies carry
owned strings/list values rather than borrowed C pointers. Shutdown settles
callbacks before unloading the core.

Support requires both the Decompbound library name and libretro's
`SET_SUPPORT_ACHIEVEMENTS` capability. The SDK's SNES/libretro mapper uses exported
system RAM (ID 2) and save RAM (ID 0), without emulated bus reads. Identification
uses the SDK's SNES hashing on a retained copy of the original ROM bytes, including
any supplied copier header; no ROM patch is applied.

With no browser or popup visible, the compositor borrows the original game image.
Achievements add no frame copy or pixel conversion to ordinary GPU presentation.
Visible UI uses separate reusable composition buffers; it never paints into the
core's image.

The pinned SDK can leave a mastery event pending after a submission completes
during idle. Its unload path clears the game before emitting that event. Shutdown
therefore settles HTTP callbacks, flushes pending events with the public
null-progress restore while the game still exists, then unloads/destroys the SDK.
This performs no additional emulated frame or RAM evaluation. A regression covers
closing during startup and after the final achievement's paused submission retry.

## Automated verification and overhead

`make test-player` includes configuration permissions, real SDK evaluation with
an isolated mock service, headered/unheadered ROM identity, both WRAM/SRAM bounds,
prefetched duplicate frames, state imports, paused submission retry, shutdown,
overlay ownership and pointer geometry. `-d:raTesting` prohibits real HTTP and
requires an explicit synthetic transport. The Xvfb integration checks menu pause,
mouse resume, held-button quarantine, state drops and normal single/DS playback;
audio uses OpenAL's null backend. Core compatibility and legacy state tests also
pass. Desktop and ARM64 player/core/helper builds are checked separately.
The SDK regressions pass under AddressSanitizer. Localhost-only production HTTPS
checks accept a trusted matching certificate and reject an untrusted certificate,
wrong DNS name, plaintext and literal-IP endpoints. No automated test signs in to
the real service or submits achievements.

On 2026-10-30, a Ryzen 9 7950X run pinned to logical CPU 2 compared the worker and
closed compositor with achievements off versus **105 active invented definitions**,
each containing two simple contradictory RAM predicates. Each of three paired
runs imported the same private cave state, warmed up for 240 frames, then measured
600 frames with identical alternating left/right input. Process CPU includes the
emulation worker; startup, real HTTPS, display/GPU and audio-device output are
excluded. Final video and generated PCM hashes agree across all six runs.

| Worker + closed overlay | CPU mean/frame | Wall p99/frame |
|---|---:|---:|
| Off | 1.024 ms | 1.171 ms |
| 105 active synthetic achievements | 1.026 ms | 1.167 ms |

Pooled CPU overhead was about **0.002 ms/frame**; the largest paired mean increase
was 0.010 ms, and the largest paired p99 increase was 0.004 ms. These fit the
0.5 ms added-CPU / 1 ms added-p99 budget. The negative pooled p99 difference is
measurement noise. This is neither an ARM result nor a cost estimate for the
real EarthBound definitions. A separate direct-core/runtime run with noisier host
clocks also stayed within those added-overhead limits. Local ignored evidence:
`build/ra-sdk/benchmark-worker/` and `build/ra-sdk/benchmark/`.

## Manual acceptance

Sign in with your own account, run a matching
Decompbound core/ROM with an isolated test save directory, and earn a real locked
achievement. Confirm the popup, browser count/details, and Casual unlock on your
account. Also check Menu/F1, back/resume, mouse/touch, both DS layouts, controller
reconnection, and accepted/rejected state imports. Test reconnection after a
temporary in-session outage without closing the app. Synthetic service tests do
not establish real service or handheld acceptance.
