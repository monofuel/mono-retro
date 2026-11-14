# Launcher

`mono-retro` has Hardware Test, System Info, Reboot, Shut Down and Decompbound entries. It uses Windy,
Pixie and Paddy, sharing the tester's device profiles and app-owned mappings.
The primary screen has a battery percentage/status toolbar. On DS Plus the
menu stays above while details, touch actions and System Info appear below.
Lost in Blue appears after Decompbound when its launch wrapper is installed.

See [games-card storage](storage.md) for the second-card mount and persistent
data layout. Existing test wrappers remain separate from everyday card-backed
play until library integration is configured.

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
Select+Start in the player to save and return. See [the player instructions](../README-player.md#rg-ds-plus).

Build both applications with `make launcher-desktop`, or cross-build with
`make launcher-handhelds`. The latter creates `build/mono-retro-arm64` and
`build/mono-retro-hwtest-arm64`. Install them as `/usr/local/bin/mono-retro`
and `/usr/local/bin/mono-retro-hwtest`. Existing tester build targets remain.
Build desktop and cross targets sequentially.

The font is embedded; no system font installation is needed. Battery percentage
sources are profile-owned (`batterySupply`): axp2202 on SP, cw2015 on stock-kernel
DS Plus, and battery on ROCKNIX-kernel DS Plus.
The toolbar separates "Plugged in" from charging state. When external power is
connected but battery current is negative, it shows "Battery draining" in amber.
System Info explains the power deficit and shows signed battery current in mA.
DS Plus uses `batteryCurrentSupply: "battery"` for RK817 current alongside the
profile's percentage source. A missing or invalid explicitly configured current source
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
